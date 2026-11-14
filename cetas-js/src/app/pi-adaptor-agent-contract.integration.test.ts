// Contract test for the refactored posoco-ext-pi-adaptor inside the real
// Cetas JS Agent (not an isolated PiPackageHost).
//
// One unmodified Pi extension is loaded from an allowlisted user package.
// Three admitted operations exercise static -> late dynamic -> active-tool
// narrowing and JSON Schema enforcement. All model traffic is intercepted;
// no credentials, network services or separate CI workflow are required.
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { newSessionId } from "./session-id.ts";

type WireTool = {
  type?: string;
  function?: { name?: string; parameters?: unknown };
};
type WireRequest = {
  messages?: Array<{ role?: string; content?: unknown }>;
  tools?: WireTool[];
};

type ScenarioOutcome = {
  loaded: boolean;
  failures: string[];
  errors: string[];
  turns: string[];
  toolCatalogs: string[][];
  schema: unknown;
  executionLog: string[];
  modelCalls: number[];
};

const MODEL_BASE = "http://cetas.test/v1";
const TOOL_ID = "call-pi-contract";
const fixtureUrl = new URL("../../smokes/fixtures/pi-agent-contract.mjs", import.meta.url);

function sse(...events: Array<Record<string, unknown> | string>): string {
  return events.map((event) =>
    "data: " + (typeof event === "string" ? event : JSON.stringify(event))
  ).join("\n\n") + "\n\n";
}

function toolStream(name: string, args: unknown): string {
  return sse(
    { choices: [{ delta: { tool_calls: [{
      index: 0,
      id: TOOL_ID,
      type: "function",
      function: { name, arguments: JSON.stringify(args) },
    }] }, finish_reason: null }] },
    { choices: [{ finish_reason: "tool_calls" }],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } },
    "[DONE]",
  );
}

function textStream(message: string): string {
  return sse(
    { choices: [{ delta: { content: message } }] },
    { choices: [{ finish_reason: "stop" }],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } },
    "[DONE]",
  );
}

async function runScenario(): Promise<ScenarioOutcome> {
  const result: ScenarioOutcome = {
    loaded: false, failures: [], errors: [], turns: [],
    toolCatalogs: [], schema: null, executionLog: [], modelCalls: [],
  };
  const tempDirs: string[] = [];
  const originalFetch = globalThis.fetch;
  const originalLog = process.env.CETAS_PI_CONTRACT_LOG;
  let app: CetasApplication | undefined;
  let phase = -1;
  let calls = 0;
  try {
    const home = await mkdtemp(join(tmpdir(), "cetas-pi-contract-home-"));
    const cwd = await mkdtemp(join(tmpdir(), "cetas-pi-contract-cwd-"));
    tempDirs.push(home, cwd);
    const dir = join(home, ".cetas", "pi-packages", "contract-probe");
    await mkdir(dir, { recursive: true });
    const logFile = join(home, "pi-contract-executions.log");
    process.env.CETAS_PI_CONTRACT_LOG = logFile;

    await writeFile(join(home, ".cetas", "settings.json"), JSON.stringify({
      providers: { deepseek: {
        api_key: "fixture-only-key",
        base_url: MODEL_BASE,
        model: "scripted-model",
      } },
    }));
    await writeFile(join(dir, "package.json"), JSON.stringify({
      name: "contract-probe",
      version: "0.0.0",
      private: true,
      pi: { extensions: ["./index.mjs"] },
    }));
    await writeFile(join(dir, "index.mjs"), await readFile(fixtureUrl, "utf8"));
    await writeFile(join(home, ".cetas", "pi-packages.json"), JSON.stringify({
      packages: ["contract-probe"],
    }));

    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (!url.startsWith("http://cetas.test/")) {
        return originalFetch.call(globalThis, input, init);
      }
      if (url.endsWith("/models")) {
        return new Response(JSON.stringify({
          object: "list",
          data: [{ id: "scripted-model", object: "model", owned_by: "fixture" }],
        }), { headers: { "content-type": "application/json" } });
      }
      const raw = init?.body == null ? "" :
        typeof init.body === "string" ? init.body :
        new TextDecoder().decode(init.body as Uint8Array);
      const body = JSON.parse(raw) as WireRequest;
      // Only record the first model request of each admitted operation.
      if (calls === 0 && phase >= 0) {
        const tools = body.tools ?? [];
        result.toolCatalogs.push(tools.map((tool) => tool.function?.name ?? ""));
        if (phase === 1) {
          result.schema = tools.find((tool) =>
            tool.function?.name === "pi_late_constrained"
          )?.function?.parameters ?? null;
        }
      }
      const response = calls++ === 0
        ? phase === 0 ? toolStream("pi_install_late", {})
        : phase === 1 ? toolStream("pi_late_constrained", { count: 0, mode: null })
        : toolStream("pi_late_constrained", { count: 2, mode: null })
        : textStream("phase-" + phase + "-completed");
      return new Response(response, {
        headers: { "content-type": "text/event-stream" },
      });
    }) as typeof fetch;

    const config = buildCetasHostConfig({ home, cwd });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config),
      config,
      callbacks: {
        observerCallback: () => undefined,
        renderCallback: () => undefined,
        requestCallback: async (json: string): Promise<string> => {
          const request = JSON.parse(json) as { request_id?: string };
          return JSON.stringify({
            type: "ui_response",
            request_id: request.request_id ?? "",
            response: { type: "yes" },
          });
        },
      },
      initialSessionId: newSessionId(),
    });
    const setup = await app.start();
    if (setup.state === "needs_setup") {
      result.errors.push("provider setup needed");
      return result;
    }
    const pi = setup.piPackages ?? app.snapshot().piPackages;
    result.loaded = pi !== undefined &&
      pi.entries === 1 && pi.failures.length === 0;
    result.failures = [...(pi?.failures ?? [])];
    if (!result.loaded) return result;

    for (phase = 0; phase < 3; phase++) {
      calls = 0;
      try {
        result.turns.push(await app.runTurn(
          phase === 0
            ? "Call pi_install_late to register the follow-up tool."
            : phase === 1
            ? "Call pi_late_constrained with count zero."
            : "Call pi_late_constrained with count two.",
        ));
      } catch (error) {
        result.errors.push("phase " + phase + ": " +
          (error instanceof Error ? error.message : String(error)));
        break;
      }
      result.modelCalls.push(calls);
    }
    try {
      result.executionLog = (await readFile(logFile, "utf8")).split("\n")
        .filter((line) => line.trim().length > 0);
    } catch {
      result.executionLog = [];
    }
  } catch (error) {
    result.errors.push(error instanceof Error ? error.message : String(error));
  } finally {
    try {
      await app?.shutdown();
    } catch (error) {
      result.errors.push("shutdown: " +
        (error instanceof Error ? error.message : String(error)));
    }
    globalThis.fetch = originalFetch;
    if (originalLog === undefined) delete process.env.CETAS_PI_CONTRACT_LOG;
    else process.env.CETAS_PI_CONTRACT_LOG = originalLog;
    for (const dir of tempDirs) {
      await rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  }
  return result;
}

const scenario = process.argv.includes("--pi-contract-scenario");
if (scenario) {
  const timeout = setTimeout(() => {
    console.error("pi contract scenario timed out");
    process.exit(3);
  }, 120_000);
  const result = await runScenario();
  clearTimeout(timeout);
  console.log("SCENARIO_RESULT " + JSON.stringify(result));
  process.exit(result.loaded && result.errors.length === 0 &&
    result.turns.length === 3 ? 0 : 1);
} else {
  let cached: { code: number; result: ScenarioOutcome; output: string } | null = null;
  function outcome() {
    if (cached !== null) return cached;
    const child = Bun.spawnSync({
      cmd: [process.execPath, import.meta.path, "--pi-contract-scenario"],
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env } as Record<string, string>,
    });
    const output = child.stdout.toString() + child.stderr.toString();
    const line = output.split("\n").find((line) => line.startsWith("SCENARIO_RESULT "));
    if (line === undefined) throw new Error(output);
    cached = {
      code: child.exitCode ?? 1,
      result: JSON.parse(line.slice("SCENARIO_RESULT ".length)) as ScenarioOutcome,
      output,
    };
    return cached;
  }

  describe("Pi extension inside the Posoco/Cetas agent", () => {
    test("loads unchanged Pi extension and finishes three operations", () => {
      const { code, result, output } = outcome();
      expect(code, output).toBe(0);
      expect(result.loaded, output).toBe(true);
      expect(result.errors, output).toEqual([]);
      expect(result.failures, output).toEqual([]);
      expect(result.turns).toHaveLength(3);
      expect(result.toolCatalogs).toHaveLength(3);
      expect(result.modelCalls.every((n) => n >= 2)).toBe(true);
    }, 120_000);

    test("late tool becomes visible only in a subsequent operation", () => {
      const { result } = outcome();
      expect(result.toolCatalogs[0]).toContain("pi_install_late");
      expect(result.toolCatalogs[0]).toContain("pi_hidden_probe");
      expect(result.toolCatalogs[0]).not.toContain("pi_late_constrained");
      expect(result.toolCatalogs[1]).toContain("pi_late_constrained");
      expect(result.toolCatalogs[2]).toContain("pi_late_constrained");
    }, 120_000);

    test("setActiveTools narrows Posoco visibility without kernel takeover", () => {
      const { result } = outcome();
      expect(result.toolCatalogs[1]).not.toContain("pi_hidden_probe");
      expect(result.toolCatalogs[2]).not.toContain("pi_hidden_probe");
      expect(result.executionLog).not.toContain("hidden-ran");
    }, 120_000);

    test("Posoco rejects invalid parameters and preserves full Pi schema", () => {
      const { result } = outcome();
      const schema = result.schema as {
        properties?: { count?: { minimum?: number; maximum?: number };
          mode?: { anyOf?: unknown[] } };
      } | null;
      expect(schema?.properties?.count?.minimum).toBe(1);
      expect(schema?.properties?.count?.maximum).toBe(3);
      expect(schema?.properties?.mode?.anyOf).toHaveLength(2);
      // Invalid count 0 must never reach the foreign execute callback.
      // The last operation's valid count 2 must reach it exactly once.
      expect(result.executionLog).toHaveLength(1);
      expect(JSON.parse(result.executionLog[0]!)).toEqual({
        count: 2, mode: null,
      });
    }, 120_000);
  });
}
