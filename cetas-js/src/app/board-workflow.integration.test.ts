import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";

interface View {
  board: {
    revision: string;
    tasks: { id: string; stage: string; execution_authorized: boolean }[];
    attempts: { id: string; task_id: string; kind: string; status: string }[];
    expansions: { id: string; parent: string; mapping: { key: string; task_id: string }[] }[];
  };
  workflow: {
    workflow_id: string;
    phase: string;
    scope_size: number;
    scope: string[];
    remaining_executions: number;
    settled_executions: number;
    succeeded_executions?: number;
    admitted_executions?: number;
    remaining_expansions: number;
    generated_tasks: number;
    remaining_generated_tasks: number;
    expansions_committed: number;
    scope_authorizations: number;
    blocked: { task_id: string; reasons: string[] }[];
  } | null;
  executions: { task_id: string; attempt_id: string; phase: string; outcome: string }[];
  unresolved: boolean;
}

interface Preview {
  proposal_id: string;
  task_count: number;
  tasks: { key: string; depends_on: Record<string, string>[] }[];
}

type Outcome = { type: string; reason?: string; structured?: unknown };

interface UiRequestEvent {
  request_id: string;
  request: { type: string; prompt?: string; title?: string; options?: string[] };
}

// Operator-side trusted strings. None of these may ever reach the durable
// identity journal: approvals, inputs and evidence stay host-held, and the
// journal carries identities and phases only.
const TITLE = "Two task DAG acceptance";
const RESTART_TITLE = "Restarted bounded workflow";
const REQUIREMENTS = "Trusted operator requirements for a two task DAG";
const FOUNDATION_INPUT = "Trusted execution input for the foundation task only";
const DEPENDENT_INPUT = "Trusted execution input for the dependent task only";
const EVIDENCE = [
  "Operator independently verified foundation is running",
  "Operator independently reviewed foundation output",
  "Operator independently accepted foundation as Done",
];

// The two-task DAG the planning Agent proposes: one proposal-local edge so the
// second Task may not run before the first is legally moved to Done.
const TWO_TASK_DAG = [
  {
    key: "foundation",
    title: "Foundation task",
    description: "Untrusted foundation task data",
    priority: "normal",
    definition_of_done: ["Evidence inspected"],
    depends_on: [],
  },
  {
    key: "dependent",
    title: "Dependent task",
    description: "Untrusted dependent task data",
    priority: "normal",
    definition_of_done: ["Evidence inspected"],
    depends_on: [{ local: "foundation" }],
  },
];

const sseResponse = (content: string) => {
  const chunks = [
    { choices: [{ delta: { content } }] },
    { choices: [{ finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 } },
  ];
  return new Response(chunks.map(c => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
};

const requestText = (body: { messages: { content?: string | { text?: string }[] }[] }) =>
  body.messages
    .map(m => Array.isArray(m.content) ? m.content.map(c => c.text ?? "").join("") : m.content ?? "")
    .join("\n");

// Exercise the actual customer composition, command router, UI round trip,
// owned Agents and Node stores. Provider transport is deterministic in-memory;
// no provider network or child tool side effects are claimed. The guided
// /workflow surface is coordinated by stable prompt prefixes and option
// labels/ids, never by index guesswork, so presentation changes keep the
// explicit board.workflow.* flow intact.
test("cetas board workflow settles a two-task DAG only through explicit approvals, legal operator moves and two waves", async () => {
  const home = await mkdtemp(join(tmpdir(), "cetas-board-host-"));
  const cwd = join(home, "project");
  const originalFetch = globalThis.fetch;
  const requests: { model?: string; tools?: unknown[]; messages: { content?: string | { text?: string }[] }[] }[] = [];
  const prompts: string[] = [];
  const unexpected: string[] = [];
  const pickerOptions: string[][] = [];
  const titles = [TITLE, RESTART_TITLE];
  const evidence = [...EVIDENCE];
  const stageChoices: string[] = [];
  const taskChoices: string[] = [];
  const taskInputs = new Map<string, string>();
  let scopeDenials = 1;
  let pickersToCancel = 0;
  let rootId = "";
  let expansionId = "";
  const apps: CetasApplication[] = [];
  try {
    await mkdir(cwd);
    await mkdir(join(home, ".cetas"));
    await writeFile(join(home, ".cetas", "settings.json"), JSON.stringify({
      providers: { deepseek: { api_key: "fixture-key", base_url: "http://board.test/v1", model: "controlled" } },
      workflow: { enabled: true, max_executions: 3, max_concurrency: 1,
        max_elapsed_ms: 60000, execution_timeout_ms: 10000, max_expansions: 1, max_generated_tasks: 4 },
    }));
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://models.dev/api.json") return Response.json({});
      if (!url.startsWith("http://board.test/")) throw new Error(`Unexpected network: ${url}`);
      if (url.endsWith("/models")) return Response.json({ object: "list", data: [{ id: "controlled", object: "model" }] });
      const body = await new Response(init?.body).json() as {
        model?: string; tools?: unknown[]; messages: { content?: string | { text?: string }[] }[];
      };
      requests.push(body);
      const prompt = requestText(body);
      const envelope = /Envelope\/schema: (.+)\nAuthorized user requirements:/.exec(prompt)?.[1];
      const content = envelope
        ? JSON.stringify({ ...JSON.parse(envelope), tasks: TWO_TASK_DAG })
        : "Controlled execution completed; operator evidence still required.";
      return sseResponse(content);
    }) as typeof fetch;
    const respond = async (raw: string): Promise<string> => {
      const event = JSON.parse(raw) as UiRequestEvent;
      const { type } = event.request;
      const text = event.request.prompt ?? event.request.title ?? "";
      const options = event.request.options ?? [];
      prompts.push(text.split("\n")[0]!);
      const reply = (response: unknown) =>
        JSON.stringify({ type: "ui_response", request_id: event.request_id, response });
      const indexOfTask = (id: string) => {
        const index = options.findIndex(option => option.includes(id));
        if (index < 0) unexpected.push(`select for ${id}: ${JSON.stringify(options)}`);
        return index < 0 ? 0 : index;
      };
      if (type === "select") {
        if (pickersToCancel > 0) {
          pickersToCancel -= 1;
          pickerOptions.push(options);
          return reply({ type: "cancelled" });
        }
        if (text.startsWith("Authorize one planning run for this parent")) return reply({ type: "selected", index: indexOfTask(rootId) });
        if (text.startsWith("Committed expansion")) return reply({ type: "selected", index: indexOfTask(expansionId) });
        if (text.startsWith("Authorized generated Task to prepare") || text.startsWith("Task to move after verifying evidence")) {
          const wanted = taskChoices.shift();
          if (wanted === undefined) {
            unexpected.push(`unexpected task select: ${text.split("\n")[0]}`);
            return reply({ type: "cancelled" });
          }
          return reply({ type: "selected", index: indexOfTask(wanted) });
        }
        if (text.startsWith("Legal Task transition only")) {
          const wanted = stageChoices.shift();
          const index = options.indexOf(wanted ?? "\u0000-never-offered");
          if (wanted === undefined || index < 0) {
            unexpected.push(`illegal or unexpected stage ${wanted}: ${JSON.stringify(options)}`);
            return reply({ type: "cancelled" });
          }
          return reply({ type: "selected", index });
        }
        unexpected.push(`unexpected select: ${text.split("\n")[0]} ${JSON.stringify(options)}`);
        return reply({ type: "cancelled" });
      }
      if (type === "input") {
        if (/workflow title/i.test(text)) {
          const title = titles.shift();
          if (title === undefined) unexpected.push("unexpected title input");
          return reply({ type: "text", text: title ?? "" });
        }
        if (text.startsWith("Trusted planning requirements")) return reply({ type: "text", text: REQUIREMENTS });
        if (text.startsWith("Trusted execution input")) {
          const id = [...taskInputs.keys()].find(candidate => text.includes(candidate));
          const input = id === undefined ? undefined : taskInputs.get(id);
          if (id === undefined || input === undefined) {
            unexpected.push(`unexpected execution input: ${text.split("\n")[0]}`);
            return reply({ type: "text", text: "" });
          }
          taskInputs.delete(id);
          return reply({ type: "text", text: input });
        }
        if (text.startsWith("Confirm the evidence")) {
          const next = evidence.shift();
          if (next === undefined) {
            unexpected.push("unexpected evidence request");
            return reply({ type: "text", text: "" });
          }
          return reply({ type: "text", text: next });
        }
        unexpected.push(`unexpected input: ${text.split("\n")[0]}`);
        return reply({ type: "text", text: "" });
      }
      if (type === "confirm") {
        if (text.includes("EXECUTION SCOPE APPROVAL") && scopeDenials > 0) {
          scopeDenials -= 1;
          return reply({ type: "no" });
        }
        return reply({ type: "yes" });
      }
      unexpected.push(`unexpected request: ${type}`);
      return reply({ type: "cancelled" });
    };
    const callbacks = {
      observerCallback: () => undefined,
      renderCallback: () => undefined,
      requestCallback: respond,
    };
    const config = buildCetasHostConfig({ home, cwd, permissionMode: "interactive" });
    const compose = (sessionId: string) => {
      const app = new CetasApplication({
        bridge: new MoonbitCetasAgentBridge(config), config, initialSessionId: sessionId,
        callbacks,
      });
      apps.push(app);
      return app;
    };
    const app = compose("workflow-host-fixture");
    expect((await app.start()).state).not.toBe("needs_setup");
    expect(app.listCommands().some(c => c.id === "board.workflow.start")).toBe(true);
    const invokeId = async (id: string) => JSON.parse(await app.invokeCommand(id, "{}")) as Outcome;
    const invoke = async (action: string) => invokeId(`board.workflow.${action}`);
    const success = async (action: string) => {
      const result = await invoke(action);
      expect(result.type, `${action}: ${result.reason}`).toBe("success");
      return result.structured as View;
    };
    const status = async () => success("status");

    await success("start");
    await success("wait");
    let view = await status();
    expect(view.board.tasks).toHaveLength(1);
    rootId = view.board.tasks[0]!.id;
    expect(view.workflow).toMatchObject({ phase: "Paused", scope_size: 1, settled_executions: 0 });
    expect(view.workflow!.scope).toEqual([rootId]);

    // The /workflow opening is read-only: presenting the picker and cancelling
    // it observes the board without mutating anything or prompting again.
    const revisionBefore = view.board.revision;
    pickersToCancel = 1;
    const opened = await invokeId("board.workflow");
    pickersToCancel = 0;
    expect(opened.type).toBe("success");
    expect(pickerOptions).toHaveLength(1);
    expect(pickerOptions[0]!.length).toBeGreaterThan(0);
    view = await status();
    expect(view.board.revision).toBe(revisionBefore);
    expect(view.board.tasks).toHaveLength(1);
    expect(view.workflow).not.toBeNull();

    await success("propose");
    view = await status();
    expect(view.board.tasks).toHaveLength(1);
    expect(view.board.expansions).toHaveLength(0);
    expect(view.workflow).toMatchObject({ generated_tasks: 0, expansions_committed: 0, settled_executions: 1 });

    // The decoded proposal is readable before any commitment, and its only
    // edge is the proposal-local dependency.
    const previewOutcome = await invokeId("board.workflow.preview");
    expect(previewOutcome.type).toBe("success");
    const preview = previewOutcome.structured as Preview;
    expect(preview.task_count).toBe(2);
    expect(preview.tasks.map(t => t.key)).toEqual(["foundation", "dependent"]);
    expect(preview.tasks[0]!.depends_on).toEqual([]);
    expect(preview.tasks[1]!.depends_on).toEqual([{ local: "foundation" }]);

    // Graph approval commits the durable Tasks and nothing else.
    view = await success("graph.approve");
    expect(view.board.expansions).toHaveLength(1);
    expect(view.board.expansions[0]!.parent).toBe(rootId);
    expansionId = view.board.expansions[0]!.id;
    const mapping = new Map(view.board.expansions[0]!.mapping.map(m => [m.key, m.task_id]));
    const foundationId = mapping.get("foundation")!;
    const dependentId = mapping.get("dependent")!;
    for (const id of [foundationId, dependentId]) {
      expect(view.board.tasks.find(t => t.id === id)).toMatchObject({ stage: "Created", execution_authorized: false });
    }
    expect(view.board.attempts.some(a => a.task_id === foundationId || a.task_id === dependentId)).toBe(false);
    expect(view.workflow).toMatchObject({ scope_size: 1, generated_tasks: 2, expansions_committed: 1 });
    expect(view.workflow!.scope).toEqual([rootId]);

    // Execution scope is refused independently of the graph approval.
    const denied = await invoke("scope.approve");
    expect(denied.type).toBe("failure");
    expect(denied.reason).toBe("approval_denied");
    view = await status();
    expect(view.workflow).toMatchObject({ scope_size: 1, scope_authorizations: 0 });
    expect(view.workflow!.scope).toEqual([rootId]);
    for (const id of [foundationId, dependentId]) {
      expect(view.board.tasks.find(t => t.id === id)!.execution_authorized).toBe(false);
    }
    expect(view.board.attempts.some(a => a.task_id === foundationId || a.task_id === dependentId)).toBe(false);

    // …and a separate explicit approval is what grants execution scope.
    view = await success("scope.approve");
    expect(view.workflow).toMatchObject({ scope_size: 3, scope_authorizations: 1 });
    expect(view.workflow!.scope).toEqual([rootId, foundationId, dependentId]);
    for (const id of [foundationId, dependentId]) {
      expect(view.board.tasks.find(t => t.id === id)).toMatchObject({ stage: "Created", execution_authorized: true });
    }
    expect(view.board.attempts.some(a => a.task_id === foundationId || a.task_id === dependentId)).toBe(false);
    // An already authorized scope cannot be granted twice.
    expect((await invoke("scope.approve")).type).toBe("failure");

    // Legal preparation moves each generated Task Created → Refining → Ready
    // with its own trusted input and a queued Execute Attempt.
    taskInputs.set(foundationId, FOUNDATION_INPUT);
    taskInputs.set(dependentId, DEPENDENT_INPUT);
    taskChoices.push(foundationId, dependentId);
    await success("prepare");
    await success("prepare");
    expect(taskInputs.size).toBe(0);
    view = await status();
    for (const id of [foundationId, dependentId]) {
      expect(view.board.tasks.find(t => t.id === id)!.stage).toBe("Ready");
      expect(view.board.attempts.find(a => a.task_id === id)).toMatchObject({ kind: "Execute", status: "Queued" });
    }

    // The first wave executes only the dependency-satisfied Task.
    view = await success("run");
    view = await success("wait");
    expect(view.board.attempts.find(a => a.task_id === foundationId)!.status).toBe("Succeeded");
    expect(view.board.attempts.find(a => a.task_id === dependentId)!.status).toBe("Queued");
    expect(view.board.tasks.find(t => t.id === foundationId)!.stage).toBe("Ready");
    expect(view.board.tasks.find(t => t.id === dependentId)!.stage).toBe("Ready");
    expect(view.executions.find(e => e.task_id === foundationId)).toMatchObject({ phase: "Settled", outcome: "Some(Completed)" });
    expect(view.executions.some(e => e.task_id === dependentId)).toBe(false);
    // The dependent stays blocked on the not-yet-Done dependency: an Agent
    // success never implies Task Done, and no wave may bypass the DAG.
    const blocked = view.workflow!.blocked.find(b => b.task_id === dependentId);
    expect(blocked?.reasons.some(reason => reason.includes("DependencyNotDone"))).toBe(true);
    expect(view.workflow).toMatchObject({ phase: "Paused", settled_executions: 2, remaining_executions: 1 });

    // Only explicit evidence-backed operator moves carry the Task legally to
    // Done; each step is offered by the domain FSM itself.
    for (const stage of ["Running", "Review", "Done"] as const) {
      taskChoices.push(foundationId);
      stageChoices.push(stage);
      view = await success("move");
      expect(view.board.tasks.find(t => t.id === foundationId)!.stage).toBe(stage);
    }
    expect(view.board.tasks.find(t => t.id === dependentId)!.stage).toBe("Ready");

    // The second wave settles the dependent Task.
    view = await success("run");
    view = await success("wait");
    expect(view.board.attempts.find(a => a.task_id === dependentId)!.status).toBe("Succeeded");
    expect(view.executions.find(e => e.task_id === dependentId)).toMatchObject({ phase: "Settled", outcome: "Some(Completed)" });
    expect(view.executions).toHaveLength(3);
    expect(view.executions.every(e => e.phase === "Settled")).toBe(true);
    expect(view.board.tasks.find(t => t.id === dependentId)!.stage).toBe("Ready");
    expect(view.workflow).toMatchObject({
      phase: "Paused",
      settled_executions: 3,
      remaining_executions: 0,
      remaining_expansions: 0,
      expansions_committed: 1,
      generated_tasks: 2,
      remaining_generated_tasks: 2,
      scope_authorizations: 1,
    });
    expect(view.workflow!.succeeded_executions).toBe(3);
    const firstWorkflowId = view.workflow!.workflow_id;

    // Exactly the approvals and confirmations the flow requires, no more.
    const count = (needle: string) => prompts.filter(prompt => prompt.includes(needle)).length;
    expect(count("Start bounded workflow?")).toBe(1);
    expect(count("Run one planning Agent for parent")).toBe(1);
    expect(count("GRAPH APPROVAL")).toBe(1);
    expect(count("EXECUTION SCOPE APPROVAL")).toBe(2);
    expect(count("Authorized generated Task to prepare")).toBe(2);
    expect(count("Run the next eligible wave")).toBe(2);
    expect(unexpected).toEqual([]);

    // Three deterministic provider turns: planning without tools, then one
    // tool-carrying execution per Task carrying only its trusted input.
    expect(requests).toHaveLength(3);
    expect(requests.every(r => r.model === "controlled")).toBe(true);
    expect(requests[0]!.tools ?? []).toHaveLength(0);
    expect((requests[1]!.tools ?? []).length).toBeGreaterThan(0);
    expect((requests[2]!.tools ?? []).length).toBeGreaterThan(0);
    expect(requestText(requests[0]!)).toContain(REQUIREMENTS);
    expect(requestText(requests[1]!)).toContain(FOUNDATION_INPUT);
    expect(requestText(requests[2]!)).toContain(DEPENDENT_INPUT);
    expect(requestText(requests[1]!)).not.toContain(DEPENDENT_INPUT);
    for (const execution of [requests[1]!, requests[2]!]) {
      expect(requestText(execution)).not.toContain("Untrusted");
    }

    await app.shutdown();
    apps.shift();

    // Clean teardown: the journal lock is released and the durable identity
    // journal carries three settled executions and no operator text at all.
    const namespaces = await readdir(join(home, ".cetas", "board"));
    expect(namespaces).toHaveLength(1);
    const directory = join(home, ".cetas", "board", namespaces[0]!);
    expect(await readdir(directory)).not.toContain("execution.lock");
    const journal = JSON.parse(await readFile(join(directory, "executions.json"), "utf8")) as {
      bindings: { task_id: string; phase: string; outcome: string }[];
    };
    expect(journal.bindings).toHaveLength(3);
    expect(journal.bindings.every(b => b.phase === "settled" && b.outcome === "completed")).toBe(true);
    expect(journal.bindings.map(b => b.task_id).sort()).toEqual([foundationId, dependentId, rootId].sort());
    const journalText = JSON.stringify(journal);
    for (const secret of [TITLE, REQUIREMENTS, FOUNDATION_INPUT, DEPENDENT_INPUT, ...EVIDENCE, "Controlled execution completed"]) {
      expect(journalText).not.toContain(secret);
    }
    const boardText = (await readFile(join(directory, "board.json"), "utf8")) +
      (await readFile(join(directory, "events.jsonl"), "utf8"));
    for (const secret of [REQUIREMENTS, FOUNDATION_INPUT, DEPENDENT_INPUT, ...EVIDENCE]) {
      expect(boardText).not.toContain(secret);
    }

    // Restart authority: the stored graph, stages and settled journal reload,
    // but no execution authority resumes with them.
    const second = compose("workflow-host-fixture-restart");
    expect((await second.start()).state).not.toBe("needs_setup");
    const resumed = JSON.parse(await second.invokeCommand("board.workflow.status", "{}")) as Outcome;
    expect(resumed.type).toBe("success");
    const restored = resumed.structured as View;
    expect(restored.workflow).toBeNull();
    expect(restored.unresolved).toBe(false);
    expect(restored.board.tasks.find(t => t.id === foundationId)).toMatchObject({ stage: "Done" });
    expect(restored.board.tasks.find(t => t.id === dependentId)).toMatchObject({ stage: "Ready" });
    expect(restored.executions).toHaveLength(3);
    for (const action of ["run", "propose", "prepare"] as const) {
      const result = JSON.parse(await second.invokeCommand(`board.workflow.${action}`, "{}")) as Outcome;
      expect(result.type).toBe("failure");
      expect(result.reason).toBe("workflow_not_started");
    }
    // A fresh bounded workflow starts from a new root only; the stored Tasks
    // are never implicitly re-authorized.
    const restartOutcome = JSON.parse(await second.invokeCommand("board.workflow.start", "{}")) as Outcome;
    expect(restartOutcome.type, `restart start: ${restartOutcome.reason}`).toBe("success");
    const restarted = restartOutcome.structured as View;
    expect(restarted.workflow).not.toBeNull();
    expect(restarted.workflow!.workflow_id).not.toBe(firstWorkflowId);
    expect(restarted.workflow!.scope_size).toBe(1);
    expect(restarted.workflow!.scope).not.toContain(foundationId);
    expect(restarted.workflow!.scope).not.toContain(dependentId);
    expect(restarted.board.tasks.some(t => t.id === foundationId)).toBe(true);
    await second.shutdown();
    expect(await readdir(directory)).not.toContain("execution.lock");
    expect(await readFile(join(directory, "executions.json"), "utf8")).toContain("settled");
    expect(requests).toHaveLength(3);
  } finally {
    while (apps.length > 0) {
      const app = apps.shift()!;
      try { await app.shutdown(); } catch { /* teardown is best effort after a failure */ }
    }
    globalThis.fetch = originalFetch;
    await rm(home, { recursive: true, force: true });
  }
}, 60000);
