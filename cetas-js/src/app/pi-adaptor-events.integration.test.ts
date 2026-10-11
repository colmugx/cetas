// Integration test for the pi adaptor event bridge (formerly the
// smoke-pi-events hermetic smoke): a DIRECT-DIR synthetic pi package under a
// fake home registers the full pi on(...) family plus one tool and logs every
// payload as a JSON line (PI_EVENTS_LOG). A scripted provider drives one
// tool-call turn, and the tests assert the projected event sequence and
// payload shapes:
//   session_start → agent_start → turn_start → message_end(toolCall)
//   → tool_execution_start/update/end → message_start → message_update
//   → turn_end → agent_end → agent_settled (final message_end rides with
//   turn_end delivery).
//
// The scenario runs in its own bun SUBPROCESS (child mode via
// --pi-scenario=run): Bun's dynamic-import runtime inside the bundled lib.js
// refuses to load a second external mirrored pi entry within one process
// (resolution is cached negatively after the first module import), so each
// pi-package composition needs its own process. This file doubles as the
// child entry: spawning it with --pi-scenario=run executes the scenario and
// prints a SCENARIO_RESULT line instead of registering tests.
//
// Hermetic by construction: fake home, stubbed model endpoint at
// http://cetas.test/ — no network, no credentials.

import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { newSessionId } from "./session-id.ts";

const MODEL_BASE = "http://cetas.test/v1";

interface RecordedEvent {
  type: string;
  [key: string]: unknown;
}

interface ScenarioOutcome {
  loaded: boolean;
  failures: string[];
  errors: string[];
  reply: string;
  turnError: string;
  events: RecordedEvent[];
}

function sseDocument(...events: Array<string | null>): string {
  return events
    .filter((event) => event !== null)
    .map((event) => `data: ${event}`)
    .join("\n\n") + "\n\n";
}

function toolCallStream(): string {
  return sseDocument(
    JSON.stringify({
      choices: [{
        delta: {
          tool_calls: [{
            index: 0,
            id: "call-events-probe-1",
            type: "function",
            function: { name: "probe_ping", arguments: "{}" },
          }],
        },
        finish_reason: null,
      }],
    }),
    JSON.stringify({
      choices: [{ finish_reason: "tool_calls" }],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
    }),
    "[DONE]",
  );
}

function textStream(text: string): string {
  return sseDocument(
    JSON.stringify({ choices: [{ delta: { content: text } }] }),
    JSON.stringify({
      choices: [{ finish_reason: "stop" }],
      usage: { prompt_tokens: 30, completion_tokens: 10, total_tokens: 40 },
    }),
    "[DONE]",
  );
}

const PROBE_INDEX = `
import { appendFileSync } from "node:fs";

const logPath = process.env.PI_EVENTS_LOG;
const record = (type, payload = {}) => {
  if (!logPath) return;
  appendFileSync(logPath, JSON.stringify({ type, ...payload }) + "\\n");
};

export default function eventsProbe(pi) {
  pi.registerTool({
    name: "probe_ping",
    label: "Probe Ping",
    description: "Returns pong; emits one tool update first.",
    parameters: { type: "object", properties: {}, required: [] },
    async execute(callId, _params, _signal, onUpdate) {
      onUpdate?.({ content: [{ type: "text", text: "pinging" }] });
      return { content: [{ type: "text", text: "pong" }], details: { callId } };
    },
  });
  for (const name of [
    "session_start",
    "agent_start",
    "agent_end",
    "agent_settled",
    "turn_start",
    "turn_end",
    "message_start",
    "message_update",
    "message_end",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
  ]) {
    pi.on(name, (payload) => record(name, payload));
  }
}
`;

async function runScenario(): Promise<ScenarioOutcome> {
  const outcome: ScenarioOutcome = {
    loaded: false,
    failures: [],
    errors: [],
    reply: "",
    turnError: "",
    events: [],
  };

  const tempDirs: string[] = [];
  const realFetch = globalThis.fetch;
  let chatRequestCount = 0;
  let app: CetasApplication | undefined;

  try {
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (!url.startsWith("http://cetas.test/")) {
        return realFetch.call(globalThis, input, init);
      }
      if (url.endsWith("/models")) {
        return new Response(
          JSON.stringify({
            object: "list",
            data: [{ id: "scripted-model", object: "model", owned_by: "cetas-smoke" }],
          }),
          { headers: { "content-type": "application/json" } },
        );
      }
      chatRequestCount += 1;
      // Turn 1 = tool_calls, turn 2 = plain text; any further requests (title
      // generation, host evolution) get a plain text reply as well.
      const body = chatRequestCount === 1 ? toolCallStream() : textStream("probe ping replied pong.");
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    }) as typeof fetch;

    const logDir = await mkdtemp(join(tmpdir(), "cetas-pi-events-log-"));
    tempDirs.push(logDir);
    const eventsLog = join(logDir, "pi-events.jsonl");
    process.env.PI_EVENTS_LOG = eventsLog;
    const piAgentDir = await mkdtemp(join(tmpdir(), "cetas-pi-events-agent-dir-"));
    tempDirs.push(piAgentDir);
    process.env.PI_CODING_AGENT_DIR = piAgentDir;

    const home = await mkdtemp(join(tmpdir(), "cetas-pi-events-home-"));
    tempDirs.push(home);
    await mkdir(join(home, ".cetas", "pi-packages", "events-probe"), { recursive: true });
    await writeFile(
      join(home, ".cetas", "settings.json"),
      JSON.stringify({
        providers: {
          deepseek: {
            api_key: "smoke-test-key",
            base_url: MODEL_BASE,
            model: "scripted-model",
          },
        },
      }),
    );
    await writeFile(
      join(home, ".cetas", "pi-packages", "events-probe", "package.json"),
      JSON.stringify({
        name: "events-probe",
        version: "0.0.1",
        private: true,
        pi: { extensions: ["./index.mjs"] },
      }) + "\n",
    );
    await writeFile(
      join(home, ".cetas", "pi-packages", "events-probe", "index.mjs"),
      PROBE_INDEX,
    );
    // The snapshot doubles as the load allowlist; empty/missing denies all.
    await writeFile(
      join(home, ".cetas", "pi-packages.json"),
      JSON.stringify({ packages: ["events-probe"] }) + "\n",
    );

    const cwd = await mkdtemp(join(tmpdir(), "cetas-pi-events-cwd-"));
    tempDirs.push(cwd);
    const config = buildCetasHostConfig({ home, cwd });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config),
      config,
      callbacks: {
        observerCallback: (): void => {},
        renderCallback: (): void => {},
        // Auto-approve every UI request; the response must echo the pending
        // request_id for the JsUiPort protocol to resolve.
        requestCallback: async (json: string): Promise<string> => {
          const request = JSON.parse(json) as { request_id?: string; request?: { type?: string } };
          let response: Record<string, unknown>;
          switch (request.request?.type) {
            case "confirm":
              response = { type: "yes" };
              break;
            case "input":
              response = { type: "text", text: "" };
              break;
            case "select":
              response = { type: "selected", index: 0 };
              break;
            default:
              response = { type: "cancelled" };
          }
          return JSON.stringify({
            type: "ui_response",
            request_id: request.request_id ?? "",
            response,
          });
        },
      },
      initialSessionId: newSessionId(),
    });

    const setup = await app.start();
    if (setup.state === "needs_setup") {
      outcome.errors.push(`provider setup required: ${JSON.stringify(setup)}`);
      return outcome;
    }
    const pi = setup.piPackages ?? app.snapshot().piPackages;
    outcome.loaded = pi !== undefined && pi.packages >= 1 && pi.entries >= 1 && pi.failures.length === 0;
    outcome.failures = [...(pi?.failures ?? [])];

    try {
      outcome.reply = await app.runTurn(
        "Call the probe_ping tool once, then tell me what it returned. You must actually call the tool.",
      );
    } catch (e: unknown) {
      outcome.turnError = e instanceof Error ? e.message : String(e);
    }
    // Fire-and-forget emits settle on microtasks; give them a beat before reading.
    await new Promise((resolve) => setTimeout(resolve, 100));
    try {
      outcome.events = (await readFile(eventsLog, "utf8"))
        .split("\n")
        .filter((line) => line.trim().length > 0)
        .map((line) => JSON.parse(line) as RecordedEvent);
    } catch {
      outcome.events = [];
    }
  } catch (e: unknown) {
    outcome.errors.push(e instanceof Error ? e.message : String(e));
  } finally {
    try {
      await app?.shutdown();
    } catch (e: unknown) {
      outcome.errors.push(`shutdown: ${e instanceof Error ? e.message : String(e)}`);
    }
    globalThis.fetch = realFetch;
    delete process.env.PI_EVENTS_LOG;
    delete process.env.PI_CODING_AGENT_DIR;
    for (const dir of tempDirs.splice(0)) {
      await rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  }
  return outcome;
}

// --- child entry ----------------------------------------------------------------

const scenarioArg = process.argv.find((arg) => arg.startsWith("--pi-scenario="));

if (scenarioArg !== undefined) {
  const timeout = setTimeout(() => {
    console.error(`[pi-adaptor-events:${scenarioArg}] timed out`);
    process.exit(3);
  }, 120_000);
  const outcome = await runScenario();
  clearTimeout(timeout);
  console.log(`SCENARIO_RESULT ${JSON.stringify(outcome)}`);
  process.exit(outcome.loaded && outcome.errors.length === 0 ? 0 : 1);
} else {
  // --- test mode: run the scenario as a subprocess and assert -----------------

  interface ChildResult {
    code: number;
    outcome: ScenarioOutcome | null;
    output: string;
  }

  let child: ChildResult | undefined;

  function runChildOnce(): ChildResult {
    if (child === undefined) {
      const proc = Bun.spawnSync({
        cmd: [process.execPath, import.meta.path, "--pi-scenario=run"],
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env } as Record<string, string>,
      });
      const output = `${proc.stdout.toString()}${proc.stderr.toString()}`;
      const line = output.split("\n").find((candidate) => candidate.startsWith("SCENARIO_RESULT "));
      let outcome: ScenarioOutcome | null = null;
      if (line !== undefined) {
        try {
          outcome = JSON.parse(line.slice("SCENARIO_RESULT ".length)) as ScenarioOutcome;
        } catch {
          outcome = null;
        }
      }
      child = { code: proc.exitCode ?? 1, outcome, output };
    }
    return child;
  }

  function outcomeOrFail(): ScenarioOutcome {
    const { outcome, output } = runChildOnce();
    if (outcome === null) throw new Error(output);
    return outcome;
  }

  function orderIndexes(events: RecordedEvent[], type: string): number[] {
    return events.map((event, index) => (event.type === type ? index : -1)).filter((index) => index >= 0);
  }

  describe("pi adaptor event bridge", () => {
    test("synthetic direct-dir pi package loaded", () => {
      const outcome = outcomeOrFail();
      expect(outcome.loaded, `failures=${JSON.stringify(outcome.failures)}`).toBe(true);
      expect(outcome.errors).toHaveLength(0);
    }, 120_000);

    test("tool-call turn completes cleanly over the scripted model", () => {
      const outcome = outcomeOrFail();
      expect(outcome.turnError).toBe("");
      expect(outcome.reply.trim().length).toBeGreaterThan(0);
    }, 120_000);

    // Full family present, skeleton in pi order. Note posoco's chunk
    // dispatcher may deliver a response's stream chunks after its
    // ModelResponseReceived, so message_start/update only need to precede
    // turn_end, not the final message_end.
    test("event family delivered in pi order", () => {
      const { events } = outcomeOrFail();
      const allTypes = [
        "session_start",
        "agent_start",
        "turn_start",
        "message_end",
        "tool_execution_start",
        "tool_execution_update",
        "tool_execution_end",
        "message_start",
        "message_update",
        "turn_end",
        "agent_end",
        "agent_settled",
      ];
      const types = events.map((event) => event.type);
      const missing = allTypes.filter((type) => !types.includes(type));
      const idx = (type: string, occurrence: "first" | "last" = "first"): number => {
        const indexes = orderIndexes(events, type);
        return indexes.length === 0 ? -1 : occurrence === "first" ? indexes[0] : indexes[indexes.length - 1];
      };
      const count = (type: string): number => orderIndexes(events, type).length;
      expect(missing, `missing: ${missing.join(", ")}; sequence: ${types.join(",")}`).toHaveLength(0);
      expect(types[0]).toBe("session_start");
      expect(types[types.length - 1]).toBe("agent_settled");
      expect(idx("session_start")).toBeLessThan(idx("agent_start"));
      expect(idx("agent_start")).toBeLessThan(idx("turn_start"));
      expect(idx("turn_start")).toBeLessThan(idx("message_end"));
      expect(idx("message_end")).toBeLessThan(idx("tool_execution_start"));
      expect(idx("tool_execution_start")).toBeLessThan(idx("tool_execution_update"));
      expect(idx("tool_execution_update")).toBeLessThan(idx("tool_execution_end"));
      expect(idx("tool_execution_end")).toBeLessThan(idx("message_start"));
      expect(idx("message_start")).toBeLessThanOrEqual(idx("message_update"));
      expect(idx("message_update")).toBeLessThan(idx("turn_end"));
      expect(idx("message_end", "last")).toBeLessThan(idx("turn_end"));
      expect(idx("turn_end")).toBeLessThan(idx("agent_end"));
      expect(idx("agent_end")).toBeLessThan(idx("agent_settled"));
      expect(count("message_end")).toBeGreaterThanOrEqual(2);
      expect(count("agent_settled")).toBe(1);
      expect(count("agent_end")).toBe(1);
    }, 120_000);

    test("payload fields match pi shapes", () => {
      const { events } = outcomeOrFail();
      const sessionStart = events.find((event) => event.type === "session_start");
      const turnStart = events.find((event) => event.type === "turn_start");
      const toolStart = events.find((event) => event.type === "tool_execution_start");
      const probeCallId = typeof toolStart?.toolCallId === "string" ? toolStart.toolCallId : "";
      const toolUpdate = events.find((event) => event.type === "tool_execution_update");
      const toolEnd = events.find((event) => event.type === "tool_execution_end");
      const turnEnd = events.find((event) => event.type === "turn_end");
      const agentEnd = [...events].reverse().find((event) => event.type === "agent_end");
      const messageEnds = events.filter((event) => event.type === "message_end");
      expect(sessionStart?.reason).toBe("new");
      expect(turnStart?.turnIndex).toBe(0);
      expect(typeof turnStart?.timestamp).toBe("number");
      expect(toolStart?.toolName).toBe("probe_ping");
      expect(probeCallId.length).toBeGreaterThan(0);
      expect(toolUpdate?.toolCallId).toBe(probeCallId);
      expect(
        (toolUpdate?.partialResult as { content?: Array<{ text?: string }> } | undefined)
          ?.content?.[0]?.text,
      ).toBe("pinging");
      expect(toolEnd?.toolCallId).toBe(probeCallId);
      expect(toolEnd?.result).toBe("pong");
      expect(toolEnd?.isError).toBe(false);
      expect(
        (turnEnd?.toolResults as Array<{ role?: string; toolCallId?: string }> | undefined)?.[0]?.role,
      ).toBe("toolResult");
      expect(
        (turnEnd?.toolResults as Array<{ toolCallId?: string }> | undefined)?.[0]?.toolCallId,
      ).toBe(probeCallId);
      expect((turnEnd?.message as { role?: string } | undefined)?.role).toBe("assistant");
      expect(turnEnd?.turnIndex).toBe(0);
      expect(Array.isArray(agentEnd?.messages)).toBe(true);
      expect((agentEnd?.messages as unknown[]).length).toBeGreaterThanOrEqual(3);
      expect(
        (agentEnd?.messages as Array<{ role?: string }>).some((message) => message.role === "toolResult"),
      ).toBe(true);
      expect(messageEnds).toHaveLength(2);
      expect(
        messageEnds.every((event) => (event.message as { role?: string } | undefined)?.role === "assistant"),
      ).toBe(true);
    }, 120_000);
  });
}
