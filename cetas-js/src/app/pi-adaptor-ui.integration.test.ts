// Integration test for the pi adaptor UI reverse-bridge (formerly the
// smoke-pi-ui hermetic smoke): a DIRECT-DIR synthetic pi package under a
// fake home registers `ask_user` (a confirm/select/input triple via ctx.ui,
// plus notify / setStatus / setWidget) and a `read` shadow probe whose marker
// description must never reach the model catalog (base wins over same-name
// pi tools). The adaptor's ctx.ui rides the same TS callback pair JsUiPort
// uses, so the ask sequence crossing the bridge proves the whole reverse
// path: pi tool → MoonBit JsUiPort → TS requestCallback → correlated
// ui_response → resolved tool result.
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

import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { newSessionId } from "./session-id.ts";

const MODEL_BASE = "http://cetas.test/v1";
const SHADOW_MARKER = "PI SHADOW PROBE";

interface ScenarioOutcome {
  loaded: boolean;
  failures: string[];
  errors: string[];
  reply: string;
  turnError: string;
  catalogDeclaredAskUser: boolean;
  catalogReadCount: number;
  catalogSawMarker: boolean;
  allViewsClean: boolean;
  piConfirm: boolean;
  piSelect: boolean;
  piInput: boolean;
  inputPlaceholder: string;
  answered: boolean;
  notice: boolean;
  statusRender: boolean;
  widgetRender: boolean;
}

const FIXTURE_INDEX = `
export default function uiFixture(pi) {
  pi.registerTool({
    name: "ask_user",
    label: "Ask User",
    description: "Runs a confirm/select/input triple through ctx.ui.",
    parameters: {
      type: "object",
      properties: { question: { type: "string" } },
      required: ["question"],
    },
    async execute(callId, params, _signal, _onUpdate, ctx) {
      const confirmed = await ctx.ui.confirm("Confirm", params.question);
      const flavor = await ctx.ui.select("Pick one", ["alpha", "beta"]);
      const note = await ctx.ui.input("Say something", "type here");
      ctx.ui.notify("answers: " + confirmed + "/" + flavor + "/" + note, "info");
      ctx.ui.setStatus("ask_user", "answered");
      ctx.ui.setWidget("ask-widget", ["line-one", "line-two"]);
      return {
        content: [{ type: "text", text: "answers:" + confirmed + "/" + flavor + "/" + note }],
        details: { callId, confirmed, flavor, note, hasUI: ctx.hasUI, mode: ctx.mode },
      };
    },
  });
  pi.registerTool({
    name: "read",
    label: "Shadow Read",
    description: "${SHADOW_MARKER}: pi duplicate of a base tool name; base must win.",
    parameters: { type: "object", properties: {}, required: [] },
    execute() {
      return { content: [{ type: "text", text: "shadow-read-ran" }], details: {} };
    },
  });
}
`;

async function runScenario(): Promise<ScenarioOutcome> {
  const outcome: ScenarioOutcome = {
    loaded: false,
    failures: [],
    errors: [],
    reply: "",
    turnError: "",
    catalogDeclaredAskUser: false,
    catalogReadCount: 0,
    catalogSawMarker: false,
    allViewsClean: true,
    piConfirm: false,
    piSelect: false,
    piInput: false,
    inputPlaceholder: "",
    answered: false,
    notice: false,
    statusRender: false,
    widgetRender: false,
  };

  const tempDirs: string[] = [];
  const realFetch = globalThis.fetch;
  let chatRequestCount = 0;
  let app: CetasApplication | undefined;

  interface ModelCatalogView {
    declared: string[];
    readCount: number;
    sawMarker: boolean;
  }
  const modelCatalogs: ModelCatalogView[] = [];

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
              id: "call-ui-probe-1",
              type: "function",
              function: { name: "ask_user", arguments: JSON.stringify({ question: "Proceed?" }) },
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

  // Auto-answers in the exact ui_response shape the pi adaptor correlates on.
  const uiRequests: Array<{ request_id?: string; request?: Record<string, unknown> }> = [];

  const onRequest = async (json: string): Promise<string> => {
    const ev = JSON.parse(json) as { request_id?: string; request?: Record<string, unknown> };
    uiRequests.push(ev);
    let response: Record<string, unknown>;
    switch (ev.request?.type) {
      case "confirm":
        response = { type: "yes" };
        break;
      case "select":
        response = { type: "selected", index: 0 };
        break;
      case "input":
        response = { type: "text", text: "hi" };
        break;
      default:
        response = { type: "cancelled" };
    }
    return JSON.stringify({ type: "ui_response", request_id: ev.request_id ?? "", response });
  };

  interface RenderEvent {
    slot?: string;
    key?: string;
    body?: { type?: string; text?: string; lines?: string[] };
    ttl_ms?: number;
  }

  const renders: RenderEvent[] = [];

  const onRender = (json: string): void => {
    const ev = JSON.parse(json) as { type?: string; render?: RenderEvent };
    if (ev.type === "ui_render" && ev.render) renders.push(ev.render);
  };

  interface StartedCall {
    name: string;
    completed: boolean;
    isError: boolean;
    result: string;
  }

  const calls = new Map<string, StartedCall>();

  const onEvent = (json: string): void => {
    const ev: unknown = JSON.parse(json);
    if (typeof ev !== "object" || ev === null || !("type" in ev)) return;
    const typed = ev as {
      type: string;
      tool_call_id?: string;
      tool_name?: string;
      result?: string;
      is_error?: boolean;
    };
    if (typed.type === "tool_call_started" && typed.tool_call_id && typed.tool_name) {
      calls.set(typed.tool_call_id, {
        name: typed.tool_name,
        completed: false,
        isError: false,
        result: "",
      });
    } else if (typed.type === "tool_call_completed" && typed.tool_call_id) {
      const call = calls.get(typed.tool_call_id);
      if (call) {
        call.completed = true;
        call.isError = typed.is_error === true;
        call.result = typed.result ?? "";
      }
    }
  };

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
      try {
        const bodyText = init?.body === undefined || init?.body === null
          ? ""
          : new TextDecoder().decode(init.body as Uint8Array);
        const body = JSON.parse(bodyText) as {
          tools?: Array<{ function?: { name?: string; description?: string } }>;
        };
        const declared = (body.tools ?? [])
          .map((tool) => tool.function?.name ?? "")
          .filter((name) => name !== "");
        modelCatalogs.push({
          declared,
          readCount: declared.filter((name) => name === "read").length,
          sawMarker: bodyText.includes(SHADOW_MARKER),
        });
      } catch {
        // Body inspection is diagnostics only.
      }
      chatRequestCount += 1;
      // Turn 1 = tool_calls; the follow-up and any extra requests (title
      // generation, host evolution) get a plain text reply.
      const body = chatRequestCount === 1 ? toolCallStream() : textStream("ask_user reported: yes / alpha / hi.");
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    }) as typeof fetch;

    const home = await mkdtemp(join(tmpdir(), "cetas-pi-ui-home-"));
    tempDirs.push(home);
    await mkdir(join(home, ".cetas", "pi-packages", "pi-ui-fixture"), { recursive: true });
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
      join(home, ".cetas", "pi-packages", "pi-ui-fixture", "package.json"),
      JSON.stringify({
        name: "pi-ui-fixture",
        version: "0.0.1",
        private: true,
        pi: { extensions: ["./index.mjs"] },
      }) + "\n",
    );
    await writeFile(
      join(home, ".cetas", "pi-packages", "pi-ui-fixture", "index.mjs"),
      FIXTURE_INDEX,
    );
    // The snapshot doubles as the load allowlist; empty/missing denies all.
    await writeFile(
      join(home, ".cetas", "pi-packages.json"),
      JSON.stringify({ packages: ["pi-ui-fixture"], npmCommand: "bun" }) + "\n",
    );

    const cwd = await mkdtemp(join(tmpdir(), "cetas-pi-ui-cwd-"));
    tempDirs.push(cwd);
    const config = buildCetasHostConfig({ home, cwd });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config),
      config,
      callbacks: {
        observerCallback: onEvent,
        renderCallback: onRender,
        requestCallback: onRequest,
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
        'Call the ask_user tool with question "Proceed?" and report the answers.',
      );
    } catch (e: unknown) {
      outcome.turnError = e instanceof Error ? e.message : String(e);
    }

    const catalog = modelCatalogs[modelCatalogs.length - 1];
    outcome.catalogDeclaredAskUser = catalog?.declared.includes("ask_user") === true;
    outcome.catalogReadCount = catalog?.readCount ?? -1;
    outcome.catalogSawMarker = catalog?.sawMarker === true;
    outcome.allViewsClean = modelCatalogs.every((view) => !view.sawMarker);

    const confirms = uiRequests.filter((ev) => ev.request?.type === "confirm");
    const selects = uiRequests.filter((ev) => ev.request?.type === "select");
    const inputs = uiRequests.filter((ev) => ev.request?.type === "input");
    outcome.piConfirm = confirms.some((ev) =>
      String((ev.request as { prompt?: string }).prompt ?? "").includes("Proceed?")
    );
    outcome.piSelect = selects.some((ev) =>
      JSON.stringify((ev.request as { options?: unknown }).options ?? "").includes("alpha")
    );
    const piInput = inputs.find((ev) =>
      String((ev.request as { prompt?: string }).prompt ?? "") === "Say something"
    );
    outcome.piInput = piInput !== undefined;
    outcome.inputPlaceholder = String((piInput?.request as { placeholder?: string } | undefined)?.placeholder ?? "");

    const askCalls = [...calls.values()].filter((call) => call.name === "ask_user");
    outcome.answered = askCalls.some((call) =>
      call.completed && !call.isError && call.result.includes("answers:true/alpha/hi")
    );
    outcome.notice = renders.some((render) =>
      render.slot === "notice" && (render.body?.text ?? "").includes("answers: true/alpha/hi")
    );
    outcome.statusRender = renders.some((render) => render.slot === "status");
    outcome.widgetRender = renders.some((render) =>
      render.slot === "widget" &&
      JSON.stringify(render.body?.lines ?? []).includes("line-one")
    );
  } catch (e: unknown) {
    outcome.errors.push(e instanceof Error ? e.message : String(e));
  } finally {
    try {
      await app?.shutdown();
    } catch (e: unknown) {
      outcome.errors.push(`shutdown: ${e instanceof Error ? e.message : String(e)}`);
    }
    globalThis.fetch = realFetch;
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
    console.error(`[pi-adaptor-ui:${scenarioArg}] timed out`);
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

  function outcomeOrFail(): ScenarioOutcome {
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
    if (child.outcome === null) throw new Error(child.output);
    return child.outcome;
  }

  describe("pi adaptor UI reverse-bridge", () => {
    test("pi-ui-fixture package loads via the snapshot allowlist", () => {
      const outcome = outcomeOrFail();
      expect(outcome.loaded, `failures=${JSON.stringify(outcome.failures)}`).toBe(true);
      expect(outcome.errors).toHaveLength(0);
    }, 120_000);

    // Shadow-hide (base wins): the model catalog must declare the pi ask_user,
    // keep exactly one `read` (the base tool), and never see the probe marker.
    test("shadow-hidden pi 'read' never reaches the model catalog (base wins)", () => {
      const outcome = outcomeOrFail();
      expect(outcome.catalogDeclaredAskUser).toBe(true);
      expect(outcome.catalogReadCount).toBe(1);
      expect(outcome.catalogSawMarker).toBe(false);
      expect(outcome.allViewsClean).toBe(true);
    }, 120_000);

    test("ui_request reached the TS callback with the pi prompts", () => {
      const outcome = outcomeOrFail();
      expect(outcome.piConfirm).toBe(true);
      expect(outcome.piSelect).toBe(true);
      expect(outcome.piInput).toBe(true);
      expect(outcome.inputPlaceholder).toBe("type here");
    }, 120_000);

    // The tool result reflects the stubbed answers and a Notice render carried
    // the notify() text.
    test("tool result reflects yes/alpha/hi and a Notice render was observed", () => {
      const outcome = outcomeOrFail();
      expect(outcome.answered).toBe(true);
      expect(outcome.notice).toBe(true);
      expect(outcome.statusRender).toBe(true);
      expect(outcome.widgetRender).toBe(true);
    }, 120_000);

    test("turn completed cleanly over the scripted model", () => {
      const outcome = outcomeOrFail();
      expect(outcome.turnError).toBe("");
      expect(outcome.reply.trim().length).toBeGreaterThan(0);
    }, 120_000);
  });
}
