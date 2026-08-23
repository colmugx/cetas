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

import { homedir } from "node:os";

import { ProcessTerminal, TUI } from "@earendil-works/pi-tui";

import { CetasApplication, type CetasHostConfig } from "./src/app/index.ts";
import { MoonbitCetasAgentBridge } from "./src/app/moonbit-bridge.ts";
import { TerminalShell } from "./ui/terminal-shell.ts";

async function main(): Promise<void> {
  const config: CetasHostConfig = {
    cwd: process.cwd(),
    // 0 = unbounded: the loop ends when the model stops calling tools or the
    // user aborts; the kernel budget is opt-in safety.
    maxToolRounds: 0,
    home: homedir(),
  };
  const sessionId = `session-${Date.now()}`;
  const tui = new TUI(new ProcessTerminal());
  const shell = new TerminalShell({
    tui,
    cwd: config.cwd,
    maxToolRounds: config.maxToolRounds,
    initialSessionId: sessionId,
    onExit: (code) => process.exit(code),
  });
  const app = new CetasApplication({
    bridge: new MoonbitCetasAgentBridge(config),
    config,
    callbacks: shell.callbacks,
    initialSessionId: sessionId,
    onStateChange: (snapshot) => shell.handleSnapshot(snapshot),
  });
  shell.attachApplication(app);
  process.on("SIGINT", () => shell.requestShutdown(0));
  await shell.start();
}

void main().catch((error: unknown) => {
  console.error("cetas-js fatal error", error);
  process.exit(1);
});
