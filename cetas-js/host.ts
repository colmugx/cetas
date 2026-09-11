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

import { ProcessTerminal, TuiMainScreen } from "@earendil-works/pi-tui";
import * as moonbit from "mbt:colmugx/cetas-js/lib";

import { buildCetasHostConfig, CetasApplication } from "./src/app/index.ts";
import {
  MoonbitCetasAgentBridge,
  resolvedSessionsDir,
} from "./src/app/moonbit-bridge.ts";
import { newSessionId } from "./src/app/session-id.ts";
import { TerminalShell, CETAS_TUI_HELP_NOTE } from "./ui/terminal-shell.ts";

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
