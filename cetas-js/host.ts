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

import { appendFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ProcessTerminal } from "@earendil-works/pi-tui";
import { TuiAltScreen } from "@earendil-works/pi-tui";
import * as moonbit from "mbt:colmugx/cetas-js/lib";

import { buildCetasHostConfig, CetasApplication, type CetasHostConfig } from "./src/app/index.ts";
import { bootstrapSettings } from "./src/app/settings-bootstrap.ts";
import { runUpdateCheck, updateNoticeMessage } from "./src/app/update-check.ts";
import { cetasVersion, detectChannel, detectPackageManager } from "./src/app/version.ts";
import { makeUnhandledFaultHandler } from "./src/host-fault.ts";
import {
  MoonbitCetasAgentBridge,
  resolvedSessionsDir,
} from "./src/app/moonbit-bridge.ts";
import { newSessionId } from "./src/app/session-id.ts";
import { disposeSharedPiModuleMirror } from "./src/app/pi-module-mirror.ts";
import { TerminalShell, CETAS_TUI_HELP_NOTE } from "./ui/terminal-shell.ts";
import { openInBrowser } from "./ui/workflow-board-server.ts";

// Recoverable failures belong to the Agent/tool boundary. A fault escaping
// that boundary cannot safely resume the scheduler or repaint the TUI.
let stopSurface: ((outputBroken: boolean) => void) | undefined;
const initialRawMode = process.stdin.isRaw ?? false;

function reportUnhandledFault(kind: string, error: unknown): string {
  const detail =
    error instanceof Error
      ? `${error.name}: ${error.message}\n${error.stack ?? ""}${error.cause === undefined ? "" : "\\ncause: " + (error.cause instanceof Error ? error.cause.stack ?? String(error.cause) : String(error.cause))}`
      : String(error);
  const crashPath = join(tmpdir(), "cetas-js-crash.log");
  appendFileSync(
    crashPath,
    `[${new Date().toISOString()}] ${kind} pid=${process.pid} cetas=${cetasVersion()} channel=${detectChannel()} runtime=${process.version} bun=${process.versions.bun ?? "unknown"}\n${detail}\n\n`,
  );
  return `cetas: fatal host fault (${kind}) logged to ${crashPath}`;
}

const onUnhandledFault = makeUnhandledFaultHandler({
  report: reportUnhandledFault,
  stopSurface: (outputBroken) => {
    try {
      stopSurface?.(outputBroken);
    } finally {
      // ProcessTerminal.stop writes to stdout before restoring raw mode.
      // Restore input separately even if stdout is broken or stop throws.
      try {
        process.stdin.setRawMode?.(initialRawMode);
      } finally {
        process.stdin.pause();
      }
    }
  },
  releaseResources: () => {
    disposeSharedPiModuleMirror();
    moonbit.cetas_js_herdr_release();
  },
  writeDiagnostic: (notice) => {
    writeSync(2, `${notice}\ncetas: exiting; restart to recover the persisted session.\n`);
  },
  exitFatal: () => process.exit(1),
});

process.on("unhandledRejection", (reason: unknown) => {
  onUnhandledFault("unhandled rejection", reason);
});
process.on("uncaughtException", (error: unknown) => {
  onUnhandledFault("uncaught exception", error);
});

async function main(): Promise<void> {
  const versionInfo = {
    version: cetasVersion(),
    channel: detectChannel(),
    manager: detectPackageManager(),
  };
  if (process.argv.includes("--version")) {
    console.log(`cetas-js ${versionInfo.version} (${versionInfo.channel})`);
    return;
  }
  // Distribution label for the agent-facing version line: the release
  // channel calls itself a binary; npm/dev keep their own names.
  const versionNote = `${versionInfo.version} (${versionInfo.channel === "release" ? "binary" : versionInfo.channel})`;
  const config = buildCetasHostConfig({
    hostHelpNote: CETAS_TUI_HELP_NOTE,
    versionNote,
  });
  await bootstrapSettings(config.home);
  const sessionId = newSessionId();
  // The shell is constructed before the agent exists, so it receives the
  // mutable Map and the active bridge's catalog is merged in on every state
  // change (first "ready" publication and later recompositions). Tool rows
  // only render during turns, which require the agent — late fill is safe.
  const toolLabels = new Map<string, string>();
  let activeBridge = new MoonbitCetasAgentBridge(config);
  const syncToolLabels = (): void => {
    for (const [name, ext] of Object.entries(activeBridge.toolLabels)) {
      toolLabels.set(name, ext);
    }
  };
  const tui = new TuiAltScreen(new ProcessTerminal(), false, undefined, { mouse: true, scrollToEndIndicator: () => "↓ newer messages" });
  let shell: TerminalShell;
  /**
   * Compose one application for `hostConfig`. Also the seam a cross-folder
   * `/sessions` resume uses: the fresh application's tools, workspace anchor,
   * system prompt and session bucket all follow that config's `cwd`. A
   * superseded application never repaints the shell — its shutdown state
   * publishes while the replacement is already active.
   */
  const composeApplication = (
    hostConfig: CetasHostConfig,
    initialSession: string,
  ): CetasApplication => {
    const bridge = new MoonbitCetasAgentBridge(hostConfig);
    activeBridge = bridge;
    return new CetasApplication({
      bridge,
      config: hostConfig,
      callbacks: shell.callbacks,
      initialSessionId: initialSession,
      onStateChange: (snapshot) => {
        if (activeBridge !== bridge) return;
        syncToolLabels();
        shell.handleSnapshot(snapshot);
      },
    });
  };
  shell = new TerminalShell({
    tui,
    cwd: config.cwd,
    // Resolved through the MoonBit bucket formula, never re-derived in TS.
    sessionsDir: resolvedSessionsDir(config),
    // `/sessions` → All walks `<home>/.cetas/sessions`, so the shell must
    // agree with the config's home instead of assuming the OS default.
    home: config.home,
    maxToolRounds: config.maxToolRounds,
    initialSessionId: sessionId,
    toolLabels,
    versionInfo,
    openBoardUrl: openInBrowser,
    // `/sessions` → All → a row from another project: build that project's
    // application so the following turns run in its directory. The shell
    // releases the previous application once this resolves.
    switchProject: async (cwd) => {
      const nextConfig = buildCetasHostConfig({
        cwd,
        home: config.home,
        maxToolRounds: config.maxToolRounds,
        ...(config.permissionMode === undefined
          ? {}
          : { permissionMode: config.permissionMode }),
        ...(config.hostHelpNote === undefined
          ? {}
          : { hostHelpNote: config.hostHelpNote }),
        ...(config.versionNote === undefined ? {} : { versionNote: config.versionNote }),
      });
      const app = composeApplication(nextConfig, newSessionId());
      await app.start();
      return { app, sessionsDir: resolvedSessionsDir(nextConfig) };
    },
    onExit: (code) => {
      disposeSharedPiModuleMirror();
      process.exit(code);
    },
  });
  const app = composeApplication(config, sessionId);
  shell.attachApplication(app);
  stopSurface = (outputBroken) => shell.stopForHostFault(outputBroken);
  process.on("SIGINT", () => shell.requestShutdown(0));
  process.on("SIGTERM", () => shell.requestShutdown(0));
  await shell.start();
  // Fire-and-forget, channel-scoped, at most once per 24h; a hit surfaces as
  // a muted transcript notice. Never awaited so startup latency is zero.
  if (versionInfo.channel !== "dev") {
    void runUpdateCheck({
      home: config.home,
      channel: versionInfo.channel,
      currentVersion: versionInfo.version,
      manager: versionInfo.manager,
    })
      .then((hit) => {
        if (hit !== undefined) {
          shell.surfaceNotice(
            updateNoticeMessage(versionInfo.version, hit, versionInfo.channel),
          );
        }
      })
      .catch(() => {});
  }
}

void main().catch((error: unknown) => {
  onUnhandledFault("startup failure", error);
});
