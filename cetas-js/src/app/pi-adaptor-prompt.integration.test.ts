// Integration test for the pi adaptor prompt-snippet injection: a synthetic DIRECT-DIR
// pi package registers a tool with/without promptSnippet and promptGuidelines; asserts
// one delimited <pi-tools> block injected into the system message — and no injection
// when no tool self-describes.
// Hermetic: fake home, globalThis.fetch answers only http://cetas.test/, no network.
// Each scenario runs as a bun subprocess via --pi-scenario= because bun's dynamic import caches mirrored pi-package resolution negatively — only one pi-package composition per process; --pi-scenario=<with|without> is the child entry.

import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { newSessionId } from "./session-id.ts";

const MODEL_BASE = "http://cetas.test/v1";
const DEFAULT_TIMEOUT_MS = 180_000;

const SNIPPET = "Search the fixture web and return a synthesized answer.";
const GUIDELINE = "Call probe_search before answering factual questions.";

interface ScenarioOutcome {
  loaded: boolean;
  turnClean: boolean;
  chatRequests: number;
  systemHasBlock: boolean;
  blockPieces: Record<string, boolean>;
  blockSection: string;
  failures: string[];
  errors: string[];
}

async function runScenario(withPromptFields: boolean): Promise<ScenarioOutcome> {
  const outcome: ScenarioOutcome = {
    loaded: false,
    turnClean: false,
    chatRequests: 0,
    systemHasBlock: false,
    blockPieces: {},
    blockSection: "",
    failures: [],
    errors: [],
  };

  const tempDirs: string[] = [];
  const realFetch = globalThis.fetch;
  const chatBodies: Array<{ messages?: Array<{ role?: string; content?: unknown }> }> = [];
  installModelStub();

  function sseDocument(...events: Array<Record<string, unknown> | string>): string {
    return events
      .map((event) => `data: ${typeof event === "string" ? event : JSON.stringify(event)}`)
      .join("\n\n") + "\n\n";
  }

  function installModelStub(): void {
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
      const bodyText = init?.body === undefined || init?.body === null
        ? ""
        : new TextDecoder().decode(init.body as Uint8Array);
      try {
        chatBodies.push(JSON.parse(bodyText));
      } catch {
        chatBodies.push({});
      }
      return new Response(
        sseDocument(
          { choices: [{ delta: { content: "prompt probe all set." } }] },
          {
            choices: [{ finish_reason: "stop" }],
            usage: { prompt_tokens: 30, completion_tokens: 10, total_tokens: 40 },
          },
          "[DONE]",
        ),
        { headers: { "content-type": "text/event-stream" } },
      );
    }) as typeof fetch;
  }

  function probeIndex(): string {
    const promptFields = withPromptFields
      ? `    promptSnippet: ${JSON.stringify(SNIPPET)},
    promptGuidelines: [${JSON.stringify(GUIDELINE)}],
`
      : "";
    return `
export default function promptProbe(pi) {
  pi.registerTool({
    name: "probe_search",
    label: "Probe Search",
    description: "Fixture search tool for the prompt-snippet injection test.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: [] },
${promptFields}    async execute() {
      return { content: [{ type: "text", text: "pong" }] };
    },
  });
}
`;
  }

  let app: CetasApplication | undefined;
  try {
    const home = await mkdtemp(join(tmpdir(), "cetas-pi-prompt-home-"));
    tempDirs.push(home);
    const cwd = await mkdtemp(join(tmpdir(), "cetas-pi-prompt-cwd-"));
    tempDirs.push(cwd);
    const piAgentDir = await mkdtemp(join(tmpdir(), "cetas-pi-prompt-agent-dir-"));
    tempDirs.push(piAgentDir);
    process.env.PI_CODING_AGENT_DIR = piAgentDir;
    await mkdir(join(home, ".cetas", "pi-packages", "prompt-probe"), { recursive: true });
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
      join(home, ".cetas", "pi-packages", "prompt-probe", "package.json"),
      JSON.stringify({
        name: "prompt-probe",
        version: "0.0.1",
        private: true,
        pi: { extensions: ["./index.mjs"] },
      }) + "\n",
    );
    await writeFile(join(home, ".cetas", "pi-packages", "prompt-probe", "index.mjs"), probeIndex());
    // The snapshot doubles as the load allowlist; empty/missing denies all.
    await writeFile(
      join(home, ".cetas", "pi-packages.json"),
      JSON.stringify({ packages: ["prompt-probe"] }) + "\n",
    );

    const config = buildCetasHostConfig({ home, cwd });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config),
      config,
      callbacks: {
        observerCallback: (): void => {},
        renderCallback: (): void => {},
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
    const pi = setup.piPackages ?? app.snapshot().piPackages;
    outcome.loaded = pi !== undefined && pi.packages >= 1 && pi.entries >= 1 && pi.failures.length === 0;
    outcome.failures = [...(pi?.failures ?? [])];

    chatBodies.length = 0;
    let reply = "";
    try {
      reply = await app.runTurn("Answer briefly: are the fixture tools visible?");
    } catch (e: unknown) {
      outcome.errors.push(`turn: ${e instanceof Error ? e.message : String(e)}`);
    }
    outcome.chatRequests = chatBodies.length;
    let systemContent = "";
    for (const body of chatBodies) {
      const system = (body.messages ?? []).find((message) => message.role === "system");
      if (system !== undefined) {
        systemContent = typeof system.content === "string"
          ? system.content
          : JSON.stringify(system.content);
        break;
      }
    }
    outcome.systemHasBlock = systemContent.includes("<pi-tools>");
    outcome.blockPieces = {
      open: systemContent.includes("<pi-tools>"),
      toolsSection: systemContent.includes("Available tools:"),
      snippetLine: systemContent.includes(`- probe_search: ${SNIPPET}`),
      guidelines: systemContent.includes("Guidelines:"),
      guidelineLine: systemContent.includes(`- ${GUIDELINE}`),
      close: systemContent.includes("</pi-tools>"),
      single: (systemContent.match(/<pi-tools>/g) ?? []).length === 1,
    };
    const sectionStart = systemContent.indexOf("<pi-tools>");
    outcome.blockSection = sectionStart >= 0
      ? systemContent.slice(sectionStart, systemContent.indexOf("</pi-tools>") + 11)
      : systemContent.slice(-600);
    outcome.turnClean = outcome.errors.length === 0 && reply.trim().length > 0 &&
      outcome.chatRequests >= 1;
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
  const scenario = scenarioArg.slice("--pi-scenario=".length);
  if (scenario !== "with" && scenario !== "without") {
    console.error(`unknown scenario: ${scenario}`);
    process.exit(1);
  }
  const timeout = setTimeout(() => {
    console.error(`[pi-adaptor-prompt:${scenario}] timed out after ${DEFAULT_TIMEOUT_MS}ms`);
    process.exit(3);
  }, DEFAULT_TIMEOUT_MS);
  const outcome = await runScenario(scenario === "with");
  clearTimeout(timeout);
  console.log(`SCENARIO_RESULT ${JSON.stringify(outcome)}`);
  process.exit(outcome.loaded && outcome.turnClean ? 0 : 1);
} else {
  // --- test mode: run both scenarios as subprocesses and assert ---------------

  interface ChildResult {
    code: number;
    outcome: ScenarioOutcome | null;
    output: string;
  }

  function runChild(scenario: "with" | "without"): ChildResult {
    const childEnv = { ...process.env } as Record<string, string>;
    delete childEnv.PI_CODING_AGENT_DIR;
    const proc = Bun.spawnSync({
      cmd: [process.execPath, import.meta.path, `--pi-scenario=${scenario}`],
      stdout: "pipe",
      stderr: "pipe",
      env: childEnv,
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
    return { code: proc.exitCode ?? 1, outcome, output };
  }

  let children: { withResult: ChildResult; withoutResult: ChildResult } | undefined;

  function runBothChildren() {
    if (children === undefined) {
      children = { withResult: runChild("with"), withoutResult: runChild("without") };
    }
    return children;
  }

  describe("pi adaptor prompt-snippet injection", () => {
    test(
      "with-scenario: package loads and the turn is clean (child exit 0)",
      () => {
        const { withResult } = runBothChildren();
        const withOutcome = withResult.outcome;
        expect(withOutcome).not.toBeNull();
        if (withOutcome === null) throw new Error(withResult.output);
        expect(withOutcome.loaded).toBe(true);
        expect(withOutcome.turnClean).toBe(true);
        expect(withResult.code).toBe(0);
      },
      120_000,
    );

    test(
      "model request system message carries exactly one complete <pi-tools> block",
      () => {
        const { withResult } = runBothChildren();
        const withOutcome = withResult.outcome;
        if (withOutcome === null) throw new Error(withResult.output);
        for (const [piece, ok] of Object.entries(withOutcome.blockPieces)) {
          expect(ok, `block piece "${piece}" missing; block:\n${withOutcome.blockSection}`).toBe(true);
        }
      },
      120_000,
    );

    test(
      "without-scenario: package loads, turn clean, block omitted",
      () => {
        const { withoutResult } = runBothChildren();
        const withoutOutcome = withoutResult.outcome;
        expect(withoutOutcome).not.toBeNull();
        if (withoutOutcome === null) throw new Error(withoutResult.output);
        expect(withoutOutcome.loaded).toBe(true);
        expect(withoutOutcome.turnClean).toBe(true);
        expect(withoutResult.code).toBe(0);
        expect(withoutOutcome.systemHasBlock).toBe(false);
      },
      120_000,
    );

    test(
      "both scenario children exited 0",
      () => {
        const { withResult, withoutResult } = runBothChildren();
        expect(withResult.code).toBe(0);
        expect(withoutResult.code).toBe(0);
      },
      120_000,
    );
  });
}
