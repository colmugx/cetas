/**
 * cetas-js process entry point.
 *
 * The host deliberately has no terminal rendering or provider logic. The
 * application coordinator owns the Agent lifecycle; `TerminalShell` owns the
 * pi-tui adapter and translates provider-neutral snapshots/events/commands
 * into an interactive coding-agent surface.
 *
 * Usage:
 *   bun host.ts
 */

import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ProcessTerminal, TuiMainScreen } from "@earendil-works/pi-tui";
import * as moonbit from "mbt:colmugx/cetas-js/lib";

import { buildCetasHostConfig, CetasApplication } from "./src/app/index.ts";
import {
  MoonbitCetasAgentBridge,
  resolvedSessionsDir,
} from "./src/app/moonbit-bridge.ts";
import { newSessionId } from "./src/app/session-id.ts";
import { TerminalShell, CETAS_TUI_HELP_NOTE } from "./ui/terminal-shell.ts";

// Without these handlers Bun's default terminates the process on any stray
// JS-side rejection. One known source: moonbitlang/async's JS http client
// drops the promise returned by ReadableStream.cancel(), which rejects when
// the fetch body stream already failed (e.g. ECONNRESET mid-stream) — a
// transient transport fault must end the turn, not the session.
// Full detail goes to the crash file; the transcript notice points at it.
// Registered before main() runs so no early async work can race them.
let surfaceFault: ((message: string) => void) | undefined;

function reportUnhandledFault(kind: string, error: unknown): void {
  const detail =
    error instanceof Error
      ? `${error.name}: ${error.message}\n${error.stack ?? ""}`
      : String(error);
  try {
    const crashPath = join(tmpdir(), "cetas-js-crash.log");
    appendFileSync(
      crashPath,
      `[${new Date().toISOString()}] ${kind}\n${detail}\n\n`,
    );
    surfaceFault?.(`⚠ host fault (${kind}) logged to ${crashPath}`);
  } catch {
    console.error(`cetas-js ${kind}`, error);
  }
}

process.on("unhandledRejection", (reason: unknown) => {
  reportUnhandledFault("unhandled rejection", reason);
});
process.on("uncaughtException", (error: unknown) => {
  reportUnhandledFault("uncaught exception", error);
});

async function main(): Promise<void> {
  const config = buildCetasHostConfig({ hostHelpNote: CETAS_TUI_HELP_NOTE });
  const sessionId = newSessionId();
  const bridge = new MoonbitCetasAgentBridge(config);
  // The shell is constructed before the agent exists, so it receives the
  // mutable Map and the bridge's catalog is merged in on every state change
  // (first "ready" publication and later recompositions). Tool rows only
  // render during turns, which require the agent — late fill is safe.
  const toolLabels = new Map<string, string>();
  const syncToolLabels = (): void => {
    for (const [name, ext] of Object.entries(bridge.toolLabels)) {
      toolLabels.set(name, ext);
    }
  };
  const tui = new TuiMainScreen(new ProcessTerminal());
  const shell = new TerminalShell({
    tui,
    cwd: config.cwd,
    // Resolved through the MoonBit bucket formula, never re-derived in TS.
    sessionsDir: resolvedSessionsDir(config),
    maxToolRounds: config.maxToolRounds,
    initialSessionId: sessionId,
    toolLabels,
    onExit: (code) => process.exit(code),
  });
  const app = new CetasApplication({
    bridge,
    config,
    callbacks: shell.callbacks,
    initialSessionId: sessionId,
    onStateChange: (snapshot) => {
      syncToolLabels();
      shell.handleSnapshot(snapshot);
    },
  });
  shell.attachApplication(app);
  surfaceFault = (message) => shell.surfaceHostFault(message);
  process.on("SIGINT", () => shell.requestShutdown(0));
  process.on("SIGTERM", () => shell.requestShutdown(0));
  await shell.start();
}

void main().catch((error: unknown) => {
  console.error("cetas-js fatal error", error);
  // Composition may have registered the herdr presence authority before
  // failing; no Agent lifecycle exists to release it, so drop it here.
  moonbit.cetas_js_herdr_release();
  process.exit(1);
});
