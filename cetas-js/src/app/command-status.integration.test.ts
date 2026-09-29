// A mid-turn /permission must settle while an approval ask is parked, and
// the spinner must return to the turn status instead of staying on
// "running /permission".
import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { TuiMainScreen } from "@earendil-works/pi-tui";
import { CetasApplication } from "./application.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";
import { TerminalShell } from "../../ui/terminal-shell.ts";

const cleanup: string[] = [];

async function waitFor(predicate: () => boolean, message: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await Bun.sleep(5);
  }
}

function sse(events: Array<Record<string, unknown>>): Response {
  const body =
    events.map((e) => `data: ${JSON.stringify(e)}`).join("\n\n") + "\n\ndata: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

function bashCallSse(callId: string, cmd: string): Response {
  const args = JSON.stringify({ cmd });
  return sse([
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { type: "function_call", call_id: callId, name: "bash" },
    },
    { type: "response.function_call_arguments.delta", output_index: 0, delta: args },
    {
      type: "response.completed",
      response: {
        status: "completed",
        output: [{ type: "function_call", call_id: callId, name: "bash", arguments: args }],
        usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
      },
    },
  ]);
}

function doneSse(): Response {
  return sse([
    { type: "response.output_text.delta", delta: "done" },
    {
      type: "response.completed",
      response: {
        status: "completed",
        output: [],
        usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
      },
    },
  ]);
}

async function readRequestBody(body: unknown): Promise<string> {
  return new TextDecoder().decode(body as Uint8Array);
}

const statusText = (shell: TerminalShell): string =>
  (
    shell as unknown as {
      statusLoader: { render(width: number): string[] };
    }
  ).statusLoader
    .render(80)
    .join("\n");

interface Harness {
  app: CetasApplication;
  shell: TerminalShell;
  restoreFetch(): void;
}

/**
 * One real agent over a temp workspace; the first model response is a
 * mutating bash call whose approval ask nobody answers, so the turn parks
 * busy inside the ask.
 */
async function startHarness(): Promise<Harness> {
  const cwd = await mkdtemp(join(tmpdir(), "cetas-cmd-status-"));
  const home = await mkdtemp(join(tmpdir(), "cetas-cmd-status-home-"));
  cleanup.push(cwd, home);
  await mkdir(join(home, ".cetas"), { recursive: true });
  await Bun.write(
    join(home, ".cetas/settings.json"),
    JSON.stringify({
      providers: {
        openai: {
          api_key: "test-key",
          base_url: "http://cetas.test/v1",
          model: "scripted-model",
        },
      },
    }),
  );
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input: unknown, init: { body?: unknown }) => {
    const url = String(input);
    if (!url.startsWith("http://cetas.test")) {
      return new Response("service unavailable", { status: 503 });
    }
    if (url.endsWith("/responses/compact")) {
      return new Response(JSON.stringify({ output: [] }), {
        headers: { "content-type": "application/json" },
      });
    }
    const body = await readRequestBody(init.body);
    if (body.includes("command-status: run a mutating shell command")) {
      return bashCallSse("call_status_1", "touch command-status-repro.txt");
    }
    return doneSse();
  }) as unknown as typeof fetch;
  const terminal = {
    write: () => {},
    hideCursor: () => {},
    showCursor: () => {},
    clearScreen: () => {},
    cursorTo: () => {},
    getRows: () => 40,
    getColumns: () => 120,
  };
  const tui = new TuiMainScreen(terminal as never);
  const config = { cwd, home, maxToolRounds: 4 };
  const bridge = new MoonbitCetasAgentBridge(config);
  const shell = new TerminalShell({
    tui,
    cwd,
    home,
    sessionsDir: join(home, "sessions"),
    maxToolRounds: 4,
    initialSessionId: "command-status-session",
  });
  const app = new CetasApplication({
    bridge,
    config,
    callbacks: shell.callbacks,
    initialSessionId: "command-status-session",
  });
  shell.attachApplication(app);
  await app.start();
  return {
    app,
    shell,
    restoreFetch: () => {
      globalThis.fetch = originalFetch;
    },
  };
}

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

describe("mid-turn /permission over the real bridge", () => {
  test(
    "the command settles and the spinner returns to the turn status",
    async () => {
      const harness = await startHarness();
      try {
        const turn = harness.app.runTurn("command-status: run a mutating shell command");
        await waitFor(
          () => harness.app.operationSnapshot.busy === true,
          "turn never became busy",
        );
        await waitFor(
          () => statusText(harness.shell).includes("running bash"),
          "status never showed the running tool",
        );

        // The user submits /permission mid-turn…
        await harness.shell.submit("/permission");
        // …the command settles (editor unlocked, outcome rendered)…
        expect(
          (harness.shell as unknown as { commandBusy: boolean }).commandBusy,
        ).toBe(false);
        // …and the spinner is back on the turn, not stuck on the command.
        const rendered = statusText(harness.shell);
        expect(rendered).not.toContain("running /permission");
        expect(rendered).toContain("running bash");
      } finally {
        harness.restoreFetch();
        await harness.app.shutdown().catch(() => undefined);
      }
    },
    20000,
  );

  test(
    "/permission <mode> also settles while the approval ask is parked",
    async () => {
      const harness = await startHarness();
      try {
        const turn = harness.app.runTurn("command-status: run a mutating shell command");
        await waitFor(
          () => harness.app.operationSnapshot.busy === true,
          "turn never became busy",
        );
        await waitFor(
          () => statusText(harness.shell).includes("running bash"),
          "status never showed the running tool",
        );
        const outcome = await harness.shell.submit(
          "/permission workspace_write",
        );
        expect(outcome).toBeUndefined();
        expect(
          (harness.shell as unknown as { commandBusy: boolean }).commandBusy,
        ).toBe(false);
      } finally {
        harness.restoreFetch();
        await harness.app.shutdown().catch(() => undefined);
      }
    },
    20000,
  );
});
