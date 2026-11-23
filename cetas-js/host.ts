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

import { ProcessTerminal } from "@earendil-works/pi-tui";
import { resolveLocale, setLocale } from "./src/i18n/index.ts";
import { TuiAltScreen } from "@earendil-works/pi-tui";

import { buildCetasHostConfig, CetasApplication, type CetasHostConfig } from "./src/app/index.ts";
import { bootstrapSettings } from "./src/app/settings-bootstrap.ts";
import { runUpdateCheck, updateNoticeMessage } from "./src/app/update-check.ts";
import { cetasVersion, detectChannel, detectPackageManager } from "./src/app/version.ts";
import { installHostFaultHandler } from "./src/host-fault.ts";
import {
  MoonbitCetasAgentBridge,
  resolvedSessionsDir,
} from "./src/app/moonbit-bridge.ts";
import { newSessionId } from "./src/app/session-id.ts";
import { observeLocalOwnerSession } from "./src/app/local-session-observer.ts";
import type { OwnerElection } from "./src/app/local-session-owner.ts";
import { disposeSharedPiModuleMirror } from "./src/app/pi-module-mirror.ts";
import { TerminalShell, localizedCetasTuiHelpNote } from "./ui/terminal-shell.ts";
import { openInBrowser } from "./ui/workflow-board-server.ts";

declare const __CETAS_NODE_BUNDLE__: boolean | undefined;

// Recoverable failures belong to the Agent/tool boundary. A fault escaping
// that boundary cannot safely resume the scheduler or repaint the TUI.
let stopSurface: ((outputBroken: boolean) => void) | undefined;
const onUnhandledFault = installHostFaultHandler((outputBroken) => {
  stopSurface?.(outputBroken);
});

async function main(): Promise<void> {
  setLocale(resolveLocale());
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
    hostHelpNote: localizedCetasTuiHelpNote(),
    versionNote,
  });
  await bootstrapSettings(config.home);
  // Optional same-user owner election uses the SAME OS lease as cetas-go.
  // Failure only suppresses collaboration; JS Agent startup is unchanged.
  // Keep the Bun-only FFI adapter out of the plain Node bundle.
  const ownerElection: OwnerElection =
    typeof __CETAS_NODE_BUNDLE__ !== "undefined" && __CETAS_NODE_BUNDLE__
      ? { status: "unavailable" }
      : (await import("./src/app/local-session-owner.ts")).electBunLocalOwner(config.home);
  const localOwner = ownerElection.owner;
  process.once("exit", () => localOwner?.close());
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
        localOwner?.update(snapshot.sessionId, snapshot.state === "running");
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
    observeSession: (id) => observeLocalOwnerSession(config.home, id, ownerElection.status),
    onLocalOwnerEvent: (raw, parsed) => localOwner?.publish(raw, parsed),
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
      localOwner?.close();
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
