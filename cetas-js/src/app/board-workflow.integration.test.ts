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
    attempts: { task_id: string; status: string }[];
    expansions: { id: string; mapping: { task_id: string }[] }[];
  };
  workflow: { scope_size: number; remaining_executions: number };
  executions: { task_id: string; phase: string; outcome: string }[];
}

// Exercise the actual customer composition, command router, UI round trip,
// owned Agents and Node stores. Provider transport is deterministic in-memory;
// no provider network or child tool side effects are claimed.
test("cetas-js command/UI workflow requires two approvals before real Agent execution", async () => {
  const home = await mkdtemp(join(tmpdir(), "cetas-board-host-"));
  const cwd = join(home, "project");
  const originalFetch = globalThis.fetch;
  const prompts: string[] = [];
  const requests: { model?: string; tools?: unknown[] }[] = [];
  let app: CetasApplication | undefined;
  let denyScope = true;
  try {
    await mkdir(cwd);
    await mkdir(join(home, ".cetas"));
    await writeFile(join(home, ".cetas", "settings.json"), JSON.stringify({
      providers: { deepseek: { api_key: "fixture-key", base_url: "http://board.test/v1", model: "controlled" } },
      workflow: { enabled: true, max_executions: 4, max_concurrency: 1,
        max_elapsed_ms: 60000, execution_timeout_ms: 10000 },
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
      const prompt = body.messages.map(m => Array.isArray(m.content) ? m.content.map(c => c.text ?? "").join("") : m.content ?? "").join("\n");
      const envelope = /Envelope\/schema: (.+)\nAuthorized user requirements:/.exec(prompt)?.[1];
      const content = envelope ? JSON.stringify({ ...JSON.parse(envelope), tasks: [{
        key: "work", title: "Verify implementation", description: "Untrusted task data",
        priority: "normal", definition_of_done: ["Evidence inspected"], depends_on: [],
      }] }) : "Controlled execution completed; operator evidence still required.";
      const chunks = [
        { choices: [{ delta: { content } }] },
        { choices: [{ finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 } },
      ];
      return new Response(chunks.map(c => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    }) as typeof fetch;
    const config = buildCetasHostConfig({ home, cwd, permissionMode: "interactive" });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config), config, initialSessionId: "workflow-host-fixture",
      callbacks: {
        observerCallback: () => undefined, renderCallback: () => undefined,
        requestCallback: async raw => {
          const event = JSON.parse(raw) as { request_id: string; request: { type: string; prompt?: string; title?: string } };
          const { type } = event.request;
          const prompt = event.request.prompt ?? event.request.title ?? "";
          prompts.push(prompt);
          const response = type === "confirm" ? { type: prompt.includes("EXECUTION SCOPE APPROVAL") && denyScope ? "no" : "yes" }
            : type === "select" ? { type: "selected", index: prompt.startsWith("Authorized generated Task") ? 1 : 0 }
            : type === "input" ? { type: "text", text: "Trusted operator input" } : { type: "cancelled" };
          return JSON.stringify({ type: "ui_response", request_id: event.request_id, response });
        },
      },
    });
    expect((await app.start()).state).not.toBe("needs_setup");
    expect(app.listCommands().some(c => c.id === "board.workflow.start")).toBe(true);
    const invoke = async (action: string) => JSON.parse(await app!.invokeCommand(`board.workflow.${action}`, "{}")) as {
      type: string; reason?: string; structured: View;
    };
    const success = async (action: string) => {
      const result = await invoke(action);
      expect(result.type, `${action}: ${result.reason}`).toBe("success");
      return result.structured;
    };
    await success("start");
    await success("propose");
    let view = await success("status");
    expect(view.board.tasks).toHaveLength(1);
    expect(view.board.expansions).toHaveLength(0);
    view = await success("graph.approve");
    const generated = view.board.expansions[0]!.mapping[0]!.task_id;
    expect(view.board.tasks.find(t => t.id === generated)).toMatchObject({ stage: "Created", execution_authorized: false });
    expect(view.board.attempts.some(a => a.task_id === generated)).toBe(false);
    expect((await invoke("scope.approve")).type).toBe("failure");
    view = await success("status");
    expect(view.workflow.scope_size).toBe(1);
    denyScope = false;
    view = await success("scope.approve");
    expect(view.workflow.scope_size).toBe(2);
    expect(view.board.attempts.some(a => a.task_id === generated)).toBe(false);
    await success("prepare");
    await success("run");
    view = await success("wait");
    expect(view.board.attempts.find(a => a.task_id === generated)?.status).toBe("Succeeded");
    expect(view.board.tasks.find(t => t.id === generated)?.stage).toBe("Ready");
    expect(view.executions.find(e => e.task_id === generated)).toMatchObject({ phase: "Settled", outcome: "Some(Completed)" });
    expect(view.workflow.remaining_executions).toBe(2);
    expect(requests).toHaveLength(2);
    expect(requests.every(r => r.model === "controlled")).toBe(true);
    expect(requests[0]!.tools ?? []).toHaveLength(0);
    expect((requests[1]!.tools ?? []).length).toBeGreaterThan(0);
    expect(prompts.filter(p => p.includes("GRAPH APPROVAL"))).toHaveLength(1);
    expect(prompts.filter(p => p.includes("EXECUTION SCOPE APPROVAL"))).toHaveLength(2);
    await app.shutdown();
    app = undefined;
    const namespaces = await readdir(join(home, ".cetas", "board"));
    expect(namespaces).toHaveLength(1);
    const directory = join(home, ".cetas", "board", namespaces[0]!);
    expect(await readdir(directory)).not.toContain("execution.lock");
    const journal = await readFile(join(directory, "executions.json"), "utf8");
    expect(journal).not.toContain("Trusted operator input");
    expect(journal).not.toContain("Controlled execution completed");
  } finally {
    try { await app?.shutdown(); } finally {
      globalThis.fetch = originalFetch;
      await rm(home, { recursive: true, force: true });
    }
  }
}, 30000);
