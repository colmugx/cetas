import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";

interface View {
  board: {
    tasks: { id: string; stage: string; execution_authorized: boolean }[];
    attempts: { id: string; task_id: string; kind: string; status: string }[];
    expansions: { id: string; mapping: { key: string; task_id: string }[] }[];
  };
  workflow: {
    phase: string;
    scope_size: number;
    remaining_executions: number;
    pending_proposal: string;
    expansions_committed: number;
    generated_tasks: number;
  } | null;
  executions: { task_id: string; phase: string; outcome: string }[];
  unresolved: boolean;
}

/** Command outcome wire shape; host-side refusals also carry a machine `code`. */
interface Outcome {
  type: string;
  reason?: string;
  code?: string;
  structured?: View;
}

interface WireRequest { model?: string; tools?: unknown[]; prompt: string }

/**
 * Deterministic planning replies: a proposal merged into the host envelope, a
 * plain junk reply, or a provider transport failure. Execution replies may
 * hang forever so only an operator cancellation can settle them.
 */
type PlanningReply = { kind: "proposal"; tasks: unknown[] } | { kind: "junk" } | { kind: "fail" };

const DUAL_TASK_DAG = [
  { key: "setup", title: "Prepare workspace", description: "Untrusted generated data",
    priority: "normal", definition_of_done: ["Evidence inspected"], depends_on: [] },
  { key: "followup", title: "Follow-up work", description: "Untrusted generated data",
    priority: "normal", definition_of_done: ["Evidence inspected"], depends_on: [{ local: "setup" }] },
];

const SINGLE_TASK_DAG = [
  { key: "solo", title: "Single task", description: "Untrusted generated data",
    priority: "normal", definition_of_done: ["Evidence inspected"], depends_on: [] },
];

const DEFAULT_WORKFLOW_SETTINGS = {
  enabled: true, max_executions: 4, max_concurrency: 1,
  max_elapsed_ms: 60000, execution_timeout_ms: 10000, max_expansions: 1, max_generated_tasks: 2,
};

/**
 * Deterministic operator behind the real UI round trip: confirms yes, picks
 * the first listed option, answers trusted text, and closes the read-only
 * /workflow overview without selecting anything.
 */
function createOperator() {
  const prompts: string[] = [];
  const requestCallback = async (raw: string) => {
    const event = JSON.parse(raw) as {
      request_id: string;
      request: { type: string; prompt?: string; title?: string; options?: string[] };
    };
    const { type } = event.request;
    const label = event.request.prompt ?? event.request.title ?? "";
    prompts.push(label);
    const respond = (response: Record<string, unknown>) =>
      JSON.stringify({ type: "ui_response", request_id: event.request_id, response });
    if (type === "confirm") return respond({ type: "yes" });
    if (type === "select") {
      if (
        label.startsWith("Workflow (opt-in)") ||
        label.startsWith("Board workflow — select an explicit operation")
      ) {
        return respond({ type: "cancelled" });
      }
      return respond({ type: "selected", index: 0 });
    }
    if (type === "input") {
      const text = label.includes("requirements")
        ? "Trusted planning requirements under test"
        : label.includes("execution input")
        ? "Trusted operator input under test"
        : label.includes("evidence")
        ? "Operator-verified evidence under test"
        : "Workflow under test goal";
      return respond({ type: "text", text });
    }
    return respond({ type: "cancelled" });
  };
  return { prompts, requestCallback };
}

interface Host {
  home: string;
  app: CetasApplication;
  operator: ReturnType<typeof createOperator>;
  requests: WireRequest[];
  invoke: (id: string) => Promise<{ type: string; reason?: string; code?: string; structured: View }>;
  success: (action: string) => Promise<View>;
  stopApp: () => Promise<void>;
  dispose: () => Promise<void>;
  close: () => Promise<void>;
}

interface HostOptions {
  homePrefix: string;
  /** Omitting providers composes no Agent at all. */
  providers?: boolean;
  permissionMode?: "readonly" | "interactive";
  workflowSettings?: Record<string, unknown>;
  planning: () => PlanningReply;
  execution?: () => { kind: "content"; content: string } | { kind: "hang" };
}

/**
 * Real CetasApplication + MoonbitCetasAgentBridge over a fixture home. The
 * provider transport is the only intercepted seam; router, board extension,
 * stores, journal and locks are all production code.
 */
async function openHost(options: HostOptions): Promise<Host> {
  const home = await mkdtemp(join(tmpdir(), options.homePrefix));
  await mkdir(join(home, "project"));
  await mkdir(join(home, ".cetas"));
  const providers = options.providers === false ? {} : {
    deepseek: { api_key: "fixture-key", base_url: "http://board.test/v1", model: "controlled" },
  };
  await writeFile(join(home, ".cetas", "settings.json"), JSON.stringify({
    providers,
    workflow: { ...DEFAULT_WORKFLOW_SETTINGS, ...options.workflowSettings },
  }));
  const requests: WireRequest[] = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url === "https://models.dev/api.json") return Response.json({});
    if (!url.startsWith("http://board.test/")) throw new Error(`Unexpected network: ${url}`);
    if (url.endsWith("/models")) return Response.json({ object: "list", data: [{ id: "controlled", object: "model" }] });
    const body = await new Response(init?.body).json() as {
      model?: string; tools?: unknown[]; messages: { content?: string | { text?: string }[] }[];
    };
    const prompt = body.messages.map(m => Array.isArray(m.content) ? m.content.map(c => c.text ?? "").join("") : m.content ?? "").join("\n");
    requests.push({ model: body.model, tools: body.tools, prompt });
    const reply = prompt.includes("Envelope/schema:") ? options.planning() : options.execution?.() ?? { kind: "content", content: "Controlled execution completed; operator evidence still required." };
    if (reply.kind === "fail") throw new Error("deterministic provider transport failure");
    if (reply.kind === "hang") return new Promise(() => undefined) as unknown as Response;
    const content = reply.kind === "junk" || !("tasks" in reply)
      ? "not a proposal at all"
      : JSON.stringify({ ...JSON.parse(/Envelope\/schema: (.+)\nAuthorized user requirements:/.exec(prompt)![1]!), tasks: reply.tasks });
    const chunks = [
      { choices: [{ delta: { content } }] },
      { choices: [{ finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 } },
    ];
    return new Response(chunks.map(c => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n", {
      headers: { "content-type": "text/event-stream" },
    });
  }) as typeof fetch;
  const composeApp = (sessionId: string) => {
    const config = buildCetasHostConfig({
      home, cwd: join(home, "project"),
      permissionMode: options.permissionMode ?? "interactive",
    });
    const operator = createOperator();
    const app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config), config, initialSessionId: sessionId,
      callbacks: {
        observerCallback: () => undefined, renderCallback: () => undefined,
        requestCallback: operator.requestCallback,
      },
    });
    return { app, operator };
  };
  const { app, operator } = composeApp("workflow-failure-fixture");
  const host: Host = {
    home,
    app,
    operator,
    requests,
    invoke: async id => JSON.parse(await host.app.invokeCommand(id, "{}")),
    success: async action => {
      const result = JSON.parse(await host.app.invokeCommand(`board.workflow.${action}`, "{}")) as {
        type: string; reason?: string; structured: View;
      };
      expect(result.type, `${action}: ${result.reason}`).toBe("success");
      return result.structured;
    },
    stopApp: async () => {
      await host.app.shutdown();
    },
    dispose: async () => {
      globalThis.fetch = originalFetch;
      await rm(home, { recursive: true, force: true });
    },
    close: async () => {
      await host.stopApp();
      await host.dispose();
    },
  };
  return host;
}

/** Read-only status ride on the concurrent control lane, for polling. */
async function controlView(host: Host): Promise<View> {
  return JSON.parse(await host.app.invokeCommand("board.workflow.status", "{}")).structured as View;
}

async function until(label: string, probe: () => Promise<boolean> | boolean, timeoutMs = 10000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if ((await probe()) === true) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}

test("invalid planning output fails closed, commits no graph, and needs a fresh explicit proposal", async () => {
  let planning: PlanningReply = { kind: "junk" };
  const host = await openHost({
    homePrefix: "cetas-board-invalid-",
    // Two reservations: the junk reply still consumes one, so the fresh
    // explicit proposal proves recovery rather than a free retry.
    workflowSettings: { max_expansions: 2 },
    planning: () => planning,
  });
  try {
    expect((await host.app.start()).state).not.toBe("needs_setup");
    await host.success("start");
    const denied = await host.invoke("board.workflow.propose");
    expect(denied.type, `propose: ${denied.reason}`).toBe("failure");
    expect(denied.reason).toBe("invalid_proposal");
    const view = await host.success("status");
    // The undecodable reply never mutates the durable graph.
    expect(view.board.tasks).toHaveLength(1);
    expect(view.board.expansions).toHaveLength(0);
    expect(view.board.attempts).toHaveLength(1);
    expect(view.board.attempts[0]).toMatchObject({ kind: "Execute", status: "Succeeded" });
    expect(view.executions[0]).toMatchObject({ phase: "Settled", outcome: "Some(Completed)" });
    expect(view.workflow!.pending_proposal).toBe("None");
    // Nothing awaits approval and no graph can be committed from the failure.
    expect((await host.invoke("board.workflow.preview")).reason).toContain("No decoded proposal");
    expect((await host.invoke("board.workflow.graph.approve")).reason).toBe("invalid_proposal");
    expect(host.operator.prompts.filter(p => p.includes("GRAPH APPROVAL"))).toHaveLength(0);
    // Recovery is a fresh explicit planning run, not a retry of the junk reply.
    planning = { kind: "proposal", tasks: DUAL_TASK_DAG };
    const preview = await host.success("propose") as unknown as { task_count: number };
    expect(preview.task_count).toBe(2);
    expect(host.requests).toHaveLength(2);
    expect(host.requests.every(r => (r.tools ?? []).length === 0)).toBe(true);
    const committed = await host.success("graph.approve");
    expect(committed.board.expansions).toHaveLength(1);
    expect(committed.board.expansions[0]!.mapping).toHaveLength(2);
  } finally {
    await host.close();
  }
}, 30000);

test("provider transport failure fails the planning attempt and terminates workflow authority", async () => {
  const host = await openHost({
    homePrefix: "cetas-board-transport-",
    // The failed planning run still consumed one reservation; the re-propose
    // below must reach the controller gate, not a budget guard.
    workflowSettings: { max_expansions: 2 },
    planning: () => ({ kind: "fail" }),
  });
  try {
    expect((await host.app.start()).state).not.toBe("needs_setup");
    await host.success("start");
    const denied = await host.invoke("board.workflow.propose");
    expect(denied.type, `propose: ${denied.reason}`).toBe("failure");
    expect(denied.reason).toBe("planning_agent_unavailable");
    const view = await host.success("status");
    expect(view.board.tasks).toHaveLength(1);
    expect(view.board.expansions).toHaveLength(0);
    expect(view.board.attempts[0]).toMatchObject({ kind: "Execute", status: "Failed" });
    expect(view.executions[0]).toMatchObject({ phase: "Settled", outcome: "Some(Failed)" });
    // A failed planning run ends the bounded workflow: no silent retry and no
    // implicit re-authorization inside the same authority.
    const again = await host.invoke("board.workflow.propose");
    expect(again.type, `re-propose: ${again.reason}`).toBe("failure");
    expect(again.reason).toBe("workflow_closed");
    expect(host.requests.every(r => r.model === "controlled")).toBe(true);
  } finally {
    await host.close();
  }
}, 30000);

test("missing provider composes no Agent and no workflow authority", async () => {
  const host = await openHost({
    homePrefix: "cetas-board-noprovider-",
    providers: false,
    planning: () => ({ kind: "fail" }),
  });
  try {
    expect((await host.app.start()).state).toBe("needs_setup");
    expect(host.app.listCommands().some(c => c.id.startsWith("board.workflow"))).toBe(false);
    for (const id of ["board.workflow.start", "board.workflow.propose", "board.workflow.status"]) {
      const result = await host.invoke(id);
      expect(result.type, `${id}: ${result.reason}`).toBe("failure");
      expect(result.code, `${id}: ${result.reason}`).toBe("not_ready");
    }
    // No Agent means no provider transport and no durable board state.
    expect(host.requests).toHaveLength(0);
    expect((await readdir(join(host.home, ".cetas"))).includes("board")).toBe(false);
  } finally {
    await host.close();
  }
}, 30000);

test("readonly permission denies workflow authority before any prompt or network", async () => {
  const host = await openHost({
    homePrefix: "cetas-board-readonly-",
    permissionMode: "readonly",
    planning: () => ({ kind: "fail" }),
  });
  try {
    expect((await host.app.start()).state).toBe("ready");
    expect(host.app.listCommands().some(c => c.id === "board.workflow.start")).toBe(true);
    for (const id of ["board.workflow.start", "board.workflow.prepare", "board.workflow.run", "board.workflow.move"]) {
      const result = await host.invoke(id);
      expect(result.type, `${id}: ${result.reason}`).toBe("failure");
      expect(result.reason).toBe("approval_denied");
    }
    // Read-only inspection is still available and saw nothing mutate.
    const view = await host.success("status");
    expect(view.board.tasks).toHaveLength(0);
    expect(view.board.attempts).toHaveLength(0);
    expect(view.workflow).toBe(null);
    expect(host.operator.prompts).toHaveLength(0);
    expect(host.requests).toHaveLength(0);
    expect((await readdir(join(host.home, ".cetas"))).includes("board")).toBe(false);
  } finally {
    await host.close();
  }
}, 30000);

test("cancelled execution settles as cancelled, ends the authority, and a restart never restores it", async () => {
  const host = await openHost({
    homePrefix: "cetas-board-interrupt-",
    workflowSettings: { max_generated_tasks: 1 },
    planning: () => ({ kind: "proposal", tasks: SINGLE_TASK_DAG }),
    // The owned Agent never returns: only the operator cancel settles it.
    execution: () => ({ kind: "hang" }),
  });
  let taskId = "";
  try {
    expect((await host.app.start()).state).not.toBe("needs_setup");
    await host.success("start");
    await host.success("propose");
    const committed = await host.success("graph.approve");
    taskId = committed.board.expansions[0]!.mapping[0]!.task_id;
    expect(committed.board.tasks.find(t => t.id === taskId)).toMatchObject({ stage: "Created", execution_authorized: false });
    const authorized = await host.success("scope.approve");
    expect(authorized.workflow!.scope_size).toBe(2);
    await host.success("prepare");
    expect((await controlView(host)).board.attempts.find(a => a.task_id === taskId)).toMatchObject({ status: "Queued" });
    await host.success("run");
    await until("the owned Agent to start", () => controlView(host).then(view => view.executions.some(e => e.phase === "Running")));
    expect((await host.invoke("board.workflow.cancel")).type).toBe("success");
    await until("the cancelled execution to settle", () => controlView(host).then(view => {
      const binding = view.executions.find(e => e.task_id === taskId);
      return binding !== undefined && binding.phase === "Settled";
    }));
    const settled = await host.success("wait");
    expect(settled.executions.find(e => e.task_id === taskId)).toMatchObject({ phase: "Settled", outcome: "Some(Cancelled)" });
    expect(settled.board.attempts.find(a => a.task_id === taskId)).toMatchObject({ status: "Cancelled" });
    expect(settled.workflow!.pending_proposal).toBe("None");
    expect(settled.unresolved).toBe(false);
    // Cancellation is terminal for this authority; nothing re-runs implicitly.
    const rerun = await host.invoke("board.workflow.run");
    expect(rerun.type, `run after cancel: ${rerun.reason}`).toBe("failure");
    expect(rerun.reason).toBe("workflow_closed");
    expect(host.operator.prompts.filter(p => p.includes("EXECUTION SCOPE APPROVAL"))).toHaveLength(1);
    const chatCalls = host.requests.length;
    expect(chatCalls).toBe(2);
    // The journal lock dies with the process: settled evidence only, no
    // operator input or model output ever persisted.
    await host.stopApp();
    const namespaces = await readdir(join(host.home, ".cetas", "board"));
    const directory = join(host.home, ".cetas", "board", namespaces[0]!);
    expect(await readdir(directory)).not.toContain("execution.lock");
    const journal = await readFile(join(directory, "executions.json"), "utf8");
    const parsed = JSON.parse(journal) as { bindings: { task_id: string; phase: string; outcome: string | null }[] };
    expect(parsed.bindings.every(b => b.phase === "settled")).toBe(true);
    expect(parsed.bindings.some(b => b.outcome === "cancelled")).toBe(true);
    expect(journal).not.toContain("Trusted operator input under test");
    expect(journal).not.toContain("Trusted planning requirements under test");
    // Restart on the same namespace: durable evidence persists, authority does
    // not. Stored graphs never resume execution on their own.
    const config = buildCetasHostConfig({ home: host.home, cwd: join(host.home, "project"), permissionMode: "interactive" });
    const restartOperator = createOperator();
    const restarted = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config), config, initialSessionId: "workflow-restart-fixture",
      callbacks: {
        observerCallback: () => undefined, renderCallback: () => undefined,
        requestCallback: restartOperator.requestCallback,
      },
    });
    try {
      expect((await restarted.start()).state).not.toBe("needs_setup");
      const reopened = JSON.parse(await restarted.invokeCommand("board.workflow.status", "{}")).structured as View;
      expect(reopened.workflow).toBe(null);
      expect(reopened.board.tasks.find(t => t.id === taskId)?.stage).toBe("Ready");
      expect(reopened.board.attempts.find(a => a.task_id === taskId)).toMatchObject({ status: "Cancelled" });
      expect(reopened.executions.find(e => e.task_id === taskId)).toMatchObject({ phase: "Settled", outcome: "Some(Cancelled)" });
      for (const id of ["board.workflow.propose", "board.workflow.run", "board.workflow.prepare"]) {
        const result = JSON.parse(await restarted.invokeCommand(id, "{}")) as { type: string; reason?: string };
        expect(result.type, `${id} after restart: ${result.reason}`).toBe("failure");
        expect(result.reason).toBe("workflow_not_started");
      }
      // The restart composed and inspected only; it never called the provider.
      expect(host.requests).toHaveLength(chatCalls);
    } finally {
      await restarted.shutdown();
    }
  } finally {
    await host.dispose();
  }
}, 45000);
