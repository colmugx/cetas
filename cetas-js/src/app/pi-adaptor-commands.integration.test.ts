// Integration test for the pi adaptor command face (formerly the
// smoke-pi-commands hermetic smoke): a DIRECT-DIR synthetic pi package under
// a fake home (`<home>/.cetas/pi-packages/pi-commands-fixture/`) registers
// two commands (`cmd_check`, `cmd_boom`) and one shortcut (`ctrl+shift+f9`).
//
// The adaptor projects them as `pi:`-namespaced CommandDefs (commands visible,
// shortcut invisible with a `shortcut` field), so cetas_js_list_commands must
// surface them and cetas_js_invoke_command must route `pi:<name>` /
// `pi:#<key>` ids onto the pi handlers with the positional args and ctx.
//
// The scenario runs in its own bun SUBPROCESS (child mode via
// --pi-scenario=run): Bun's dynamic-import runtime inside the bundled lib.js
// refuses to load a second external mirrored pi entry within one process
// (resolution is cached negatively after the first module import), so each
// pi-package composition needs its own process. This file doubles as the
// child entry: spawning it with --pi-scenario=run executes the scenario and
// prints a SCENARIO_RESULT line instead of registering tests.
//
// The terminal-shell dispatch is not reachable headless (it needs the pi-tui
// screen), so the slash-tokenization facts are pinned at unit level via the
// exported matchLocalSlash / parsePositionalArgs helpers.
//
// Hermetic by construction: fake home, stubbed model endpoint at
// http://cetas.test/ (composition only — no model turns), no network.

import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import { buildCetasHostConfig } from "./host-config.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { newSessionId } from "./session-id.ts";
import { matchLocalSlash, parsePositionalArgs } from "../../ui/terminal-shell.ts";

const MODEL_BASE = "http://cetas.test/v1";

const FIXTURE_INDEX = `import { appendFileSync } from "node:fs";

export default function commandFixture(pi) {
  pi.registerCommand("cmd_check", {
    description: "Returns pong:<args> and logs ctx.",
    async handler(args, ctx) {
      appendFileSync(process.env.PI_SMOKE_COMMANDS_LOG, JSON.stringify({
        kind: "command", name: "cmd_check", args, cwd: ctx.cwd,
      }) + "\\n");
      return "pong:" + args;
    },
  });
  pi.registerCommand("cmd_boom", {
    description: "Always throws.",
    handler() {
      throw new Error("smoke boom");
    },
  });
  pi.registerShortcut("ctrl+shift+f9", {
    description: "Smoke shortcut.",
    handler(ctx) {
      appendFileSync(process.env.PI_SMOKE_COMMANDS_LOG, JSON.stringify({
        kind: "shortcut", key: "ctrl+shift+f9", cwd: ctx.cwd,
      }) + "\\n");
    },
  });
}
`;

interface ScenarioOutcome {
  loaded: boolean;
  failures: string[];
  errors: string[];
  cwd: string;
  piIds: string[];
  checkDescription: string | undefined;
  checkVisible: boolean | undefined;
  shortcutVisible: boolean | undefined;
  shortcutKey: string | undefined;
  groupedLength: number;
  success: Record<string, unknown> | undefined;
  handlerLine: { args?: string; cwd?: string } | undefined;
  boom: Record<string, unknown> | undefined;
  unknown: Record<string, unknown> | undefined;
  shortcutOutcome: Record<string, unknown> | undefined;
  shortcutLine: { cwd?: string } | undefined;
}

async function runScenario(): Promise<ScenarioOutcome> {
  const outcome: ScenarioOutcome = {
    loaded: false,
    failures: [],
    errors: [],
    cwd: "",
    piIds: [],
    checkDescription: undefined,
    checkVisible: undefined,
    shortcutVisible: undefined,
    shortcutKey: undefined,
    groupedLength: 0,
    success: undefined,
    handlerLine: undefined,
    boom: undefined,
    unknown: undefined,
    shortcutOutcome: undefined,
    shortcutLine: undefined,
  };

  const tempDirs: string[] = [];
  const realFetch = globalThis.fetch;
  let app: CetasApplication | undefined;

  function parseOutcome(raw: string): Record<string, unknown> {
    return JSON.parse(raw) as Record<string, unknown>;
  }

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
      return new Response(
        JSON.stringify({ error: { message: "this scenario performs no model turns" } }),
        { status: 500, headers: { "content-type": "application/json" } },
      );
    }) as typeof fetch;

    const home = await mkdtemp(join(tmpdir(), "cetas-pi-commands-home-"));
    tempDirs.push(home);
    const logPath = join(home, "commands.log");
    process.env.PI_SMOKE_COMMANDS_LOG = logPath;
    await mkdir(join(home, ".cetas", "pi-packages", "pi-commands-fixture"), { recursive: true });
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
      join(home, ".cetas", "pi-packages", "pi-commands-fixture", "package.json"),
      JSON.stringify({
        name: "pi-commands-fixture",
        version: "0.0.1",
        private: true,
        pi: { extensions: ["./index.mjs"] },
      }) + "\n",
    );
    await writeFile(
      join(home, ".cetas", "pi-packages", "pi-commands-fixture", "index.mjs"),
      FIXTURE_INDEX,
    );
    await writeFile(
      join(home, ".cetas", "pi-packages.json"),
      JSON.stringify({ packages: ["pi-commands-fixture"], npmCommand: "bun" }) + "\n",
    );

    const cwd = await mkdtemp(join(tmpdir(), "cetas-pi-commands-cwd-"));
    tempDirs.push(cwd);
    outcome.cwd = cwd;
    const config = buildCetasHostConfig({ home, cwd });
    app = new CetasApplication({
      bridge: new MoonbitCetasAgentBridge(config),
      config,
      callbacks: {
        observerCallback: () => undefined,
        renderCallback: () => undefined,
        requestCallback: async () =>
          JSON.stringify({ type: "ui_response", request_id: "", response: { type: "cancelled" } }),
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

    const ids = app.listCommands().map((descriptor) => descriptor.id);
    outcome.piIds = ids.filter((id) => id.startsWith("pi:"));
    const checkDescriptor = app.listCommands().find((descriptor) => descriptor.id === "pi:cmd_check");
    const shortcutDescriptor = app.listCommands().find(
      (descriptor) => descriptor.id === "pi:#ctrl+shift+f9",
    );
    outcome.checkDescription = checkDescriptor?.description;
    outcome.checkVisible = checkDescriptor?.visible;
    outcome.shortcutVisible = shortcutDescriptor?.visible;
    outcome.shortcutKey = shortcutDescriptor?.shortcut;
    outcome.groupedLength = app.listCommands()
      .map((descriptor) => `/${descriptor.id}`)
      .filter((label) => label.slice(1).startsWith("pi:"))
      .length;

    try {
      outcome.success = parseOutcome(
        await app.invokeCommand("pi:cmd_check", JSON.stringify({ _positional: "smoke" })),
      );
      const lines = (await readFile(logPath, "utf8")).trim().split("\n")
        .map((line) => JSON.parse(line) as Record<string, unknown>);
      outcome.handlerLine = lines.find((line) => line.kind === "command") as { args?: string; cwd?: string };
      outcome.boom = parseOutcome(await app.invokeCommand("pi:cmd_boom", "{}"));
      outcome.unknown = parseOutcome(await app.invokeCommand("pi:nope", "{}"));
      outcome.shortcutOutcome = parseOutcome(await app.invokeCommand("pi:#ctrl+shift+f9", "{}"));
      const shortcutLines = (await readFile(logPath, "utf8")).trim().split("\n")
        .map((line) => JSON.parse(line) as Record<string, unknown>);
      outcome.shortcutLine = shortcutLines.find((line) => line.kind === "shortcut") as { cwd?: string };
    } catch (e: unknown) {
      outcome.errors.push(e instanceof Error ? e.message : String(e));
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
    delete process.env.PI_SMOKE_COMMANDS_LOG;
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
    console.error(`[pi-adaptor-commands:${scenarioArg}] timed out`);
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

  describe("pi adaptor command face", () => {
    test("pi-commands-fixture package loads via the snapshot allowlist", () => {
      const { outcome, output } = runChildOnce();
      if (outcome === null) throw new Error(output);
      expect(outcome.loaded, `failures=${JSON.stringify(outcome.failures)}`).toBe(true);
      expect(outcome.errors).toHaveLength(0);
    }, 120_000);

    test("pi: commands list grouped with shortcut def invisible but shortcut-carrying", () => {
      const { outcome, output } = runChildOnce();
      if (outcome === null) throw new Error(output);
      expect(outcome.piIds).toContain("pi:cmd_check");
      expect(outcome.piIds).toContain("pi:cmd_boom");
      expect(outcome.checkDescription).toBe("Returns pong:<args> and logs ctx.");
      expect(outcome.checkVisible).toBe(true);
      expect(outcome.shortcutVisible).toBe(false);
      expect(outcome.shortcutKey).toBe("ctrl+shift+f9");
      expect(outcome.groupedLength).toBe(outcome.piIds.length);
    }, 120_000);

    test("pi:cmd_check invoke reaches the handler with args + ctx", () => {
      const { outcome, output } = runChildOnce();
      if (outcome === null) throw new Error(output);
      expect(outcome.success?.type).toBe("success");
      expect(outcome.success?.feedback).toBe("pong:smoke");
      expect(outcome.handlerLine).toBeDefined();
      expect(outcome.handlerLine?.args).toBe("smoke");
      expect(outcome.handlerLine?.cwd).toBe(outcome.cwd);
    }, 120_000);

    test("throwing and unknown ids project as failure outcomes", () => {
      const { outcome, output } = runChildOnce();
      if (outcome === null) throw new Error(output);
      expect(outcome.boom?.type).toBe("failure");
      expect(outcome.boom?.reason).toBe("smoke boom");
      expect(outcome.unknown?.type).toBe("failure");
      expect(outcome.unknown?.reason).toBe("command not found: pi:nope");
    }, 120_000);

    test("/pi:<name> tokenizes as one extension-bound token; shortcut bridge runs", () => {
      const { outcome, output } = runChildOnce();
      if (outcome === null) throw new Error(output);
      expect(matchLocalSlash("/pi:cmd_check")).toBeUndefined();
      expect(matchLocalSlash("/pi")).toBeDefined();
      expect(parsePositionalArgs("smoke args", "/pi:cmd_check")).toBe(
        JSON.stringify({ _positional: "smoke args" }),
      );
      expect(outcome.shortcutOutcome?.type).toBe("success");
      expect(outcome.shortcutLine).toBeDefined();
      expect(outcome.shortcutLine?.cwd).toBe(outcome.cwd);
    }, 120_000);
  });
}
