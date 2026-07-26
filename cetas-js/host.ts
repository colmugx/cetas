/**
 * host.ts — cetas-js entry point.
 *
 * Composes:
 *   - MoonBit agent (cetas_js_run_turn + observer JSON events)
 *   - pi-tui primitives (TUI / Container / Editor / Markdown / Loader / Text)
 *   - cetas-js controllers (EventRouter + StreamingUIController)
 *   - cetas-js transcript (AssistantMessage + ToolRow + UserMessage)
 *   - cetas-js tool renderers (read/write/edit/bash/grep/glob)
 *
 * Layout (top → bottom):
 *   header → transcript → status (Loader) → editor → footer
 *
 * IMPORTANT: tui.children is FIXED after construction. No splice in/out of
 * streaming components — they are added to the transcript Container and stay
 * there permanently. This prevents the screen-clearing and scroll-jumping
 * that plagued the previous streamingMount splice approach.
 *
 * Usage:
 *   export DEEPSEEK=sk-...
 *   bun install
 *   bun host.ts
 */

import chalk from "chalk";
import {
  TUI,
  ProcessTerminal,
  Container,
  Editor,
  Text,
  Loader,
  type EditorTheme,
  type SelectListTheme,
  matchesKey,
} from "@earendil-works/pi-tui";

import {
  CetasJsConfig,
  cetas_js_create_agent,
  cetas_js_run_turn,
  cetas_js_shutdown,
} from "../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";
import { parseCetasEvent, type CetasEvent } from "./src/events.ts";
import {
  registerBuiltinToolRenderers,
} from "./src/tool-renderers/index.ts";
import {
  UserMessage,
  errorNotice,
} from "./src/transcript/components.ts";
import { EventRouter } from "./src/controllers/event-router.ts";
import { UiRegistry } from "./src/ui-registry.ts";
import { theme, markdownTheme } from "./ui/theme.ts";
import { blankLine, banner } from "./ui/primitives.ts";
import { DebugFooter, defaultDebugInfo } from "./ui/layout.ts";
import {
  UiRenderHost,
  UiRequestOverlay,
  createUiRenderCallback,
  createUiRequestCallback,
} from "./ui/extension-ui.ts";

// ---------------------------------------------------------------------------
// MoonBit FFI shapes — positional constructor, async run_turn.
// ---------------------------------------------------------------------------

type CetasJsCreateAgent = (
  config: unknown,
  observerCallback: (eventJson: string) => void,
  renderCallback: (eventJson: string) => void,
  requestCallback: (eventJson: string) => Promise<string>,
) => Promise<unknown>;

type CetasJsRunTurn = (
  agent: unknown,
  prompt: string,
  sessionId: string,
) => Promise<string>;

type CetasJsShutdown = (agent: unknown) => Promise<void>;

const createAgent = cetas_js_create_agent as unknown as CetasJsCreateAgent;
const runTurn = cetas_js_run_turn as unknown as CetasJsRunTurn;
const shutdownAgent = cetas_js_shutdown as unknown as CetasJsShutdown;

const ConfigCtor = CetasJsConfig as unknown as new (
  apiKey: string,
  baseUrl: string,
  model: string,
  cwd: string,
  maxToolRounds: number,
) => unknown;

// ---------------------------------------------------------------------------
// Theme glue — pi-tui Editor still consumes its own theme struct.
// ---------------------------------------------------------------------------

const identity = (s: string) => s;

const selectListTheme: SelectListTheme = {
  selectedPrefix: identity,
  selectedText: chalk.cyan,
  description: chalk.gray,
  scrollInfo: identity,
  noMatch: chalk.red,
};

const editorTheme: EditorTheme = {
  borderColor: theme.accent,
  selectList: selectListTheme,
};

// ---------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------

async function main() {
  const apiKey = process.env.DEEPSEEK;
  if (!apiKey) {
    console.error("Error: DEEPSEEK environment variable not set.");
    console.error("Get a key from https://platform.deepseek.com");
    process.exit(1);
  }

  const baseUrl = process.env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
  const model = process.env.DEEPSEEK_MODEL ?? "deepseek-chat";
  const cwd = process.cwd();
  const maxToolRounds = 20;
  const sessionId = "cetas-js-session";
  const config = new ConfigCtor(apiKey, baseUrl, model, cwd, maxToolRounds);

  // Tool renderers are a module-level side effect; calling once is belt +
  // suspenders.
  registerBuiltinToolRenderers();

  // ----- TUI scaffolding --------------------------------------------------
  const tui = new TUI(new ProcessTerminal());
  tui.setClearOnShrink(false);

  // header
  tui.addChild(new Text(theme.brandBold(" Welcome to Cetas"), 1, 0));

  // transcript container — the flat list of rendered blocks (user msgs,
  // assistant msgs, tool rows, notices). Each block component owns its own
  // leading Spacer, so we just addChild in arrival order.
  const transcriptContainer = new Container();
  tui.addChild(transcriptContainer);

  // streaming components are added directly to `transcriptContainer` via
  // the EventRouter and stay there permanently. No splice-in/out of
  // tui.children — this prevents screen-clearing and scroll jumps.

  // status indicator (Loader) — only visible when work is in progress.
  // Wrapped in a Container so it takes zero layout space when idle.
  const statusLoader = new Loader(
    tui,
    (s) => theme.accent(s),
    (s) => theme.muted(s),
    "",
  );
  const statusWrapper = new Container();
  const extensionStatus = new Container();
  const statusRegion = new Container();
  statusRegion.addChild(statusWrapper);
  statusRegion.addChild(extensionStatus);
  tui.addChild(statusRegion);

  // Custom extension widgets sit between status and the editor.
  const extensionWidgets = new Container();
  tui.addChild(extensionWidgets);

  // editor
  const editor = new Editor(tui, editorTheme);
  const uiRegistry = new UiRegistry();
  uiRegistry.register("cetas.host", {
    component_keys: [],
    autocomplete: [
      {
        trigger: "/",
        kind: "command",
        fetch: (prefix, signal) => {
          if (signal.aborted) return [];
          return [
            {
              label: "/help",
              detail: "Show slash commands",
              insert_text: "/help",
            },
            {
              label: "/clear",
              detail: "Clear the transcript",
              insert_text: "/clear",
            },
            {
              label: "/exit",
              detail: "Quit cetas-js",
              insert_text: "/exit",
            },
          ].filter((item) => item.label.slice(1).startsWith(prefix));
        },
      },
    ],
  });
  editor.setAutocompleteProvider(uiRegistry);
  tui.addChild(editor);
  tui.setFocus(editor);

  // footer — model + debug info bar
  const debugState = defaultDebugInfo(model);
  const footer = new DebugFooter(model);
  tui.addChild(footer);

  const uiRenderHost = new UiRenderHost(tui, {
    status: extensionStatus,
    notice: transcriptContainer,
    widget: extensionWidgets,
  });
  const uiRequestOverlay = new UiRequestOverlay(tui);
  const onUiRequest = createUiRequestCallback(uiRequestOverlay, 300_000);

  // ----- Event router ----------------------------------------------------
  const router = new EventRouter({
    addTranscriptChild: (c) => {
      transcriptContainer.addChild(c);
      tui.requestRender();
    },
    setStatus: (kind, message) => {
      if (kind === "idle") {
        statusWrapper.clear();
        statusLoader.stop();
      } else {
        statusLoader.setMessage(message ?? "working");
        statusLoader.start();
        statusWrapper.clear();
        statusWrapper.addChild(statusLoader);
      }
      tui.requestRender();
    },
    requestRender: () => tui.requestRender(),
    cwd,
  });

  // ----- Turn lifecycle --------------------------------------------------
  let inTurn = false;
  let turnStartTime = 0;

  const onEvent = (eventJson: string) => {
    const parsed: unknown = JSON.parse(eventJson);
    const ev = parseCetasEvent(parsed) as CetasEvent | null;
    if (!ev) {
      throw new Error("unknown or malformed cetas event");
    }

    // Track debug counters for the footer.
    switch (ev.type) {
      case "turn_started":
        turnStartTime = Date.now();
        debugState.turnCount++;
        debugState.toolsThisTurn = 0;
        debugState.tokensInput = 0;
        debugState.tokensOutput = 0;
        debugState.latencyMs = 0;
        debugState.sessionId = sessionId;
        footer.update(debugState);
        break;
      case "tool_call_started":
        debugState.toolsThisTurn++;
        footer.update(debugState);
        break;
      case "model_invoked":
        if (ev.usage) {
          debugState.tokensInput += ev.usage.input_tokens ?? 0;
          debugState.tokensOutput += ev.usage.output_tokens ?? 0;
        }
        footer.update(debugState);
        break;
      case "turn_completed":
      case "turn_failed":
        debugState.latencyMs = Date.now() - turnStartTime;
        footer.update(debugState);
        break;
      default:
        break;
    }

    router.handleEvent(ev);
  };

  const onUiRender = createUiRenderCallback(uiRenderHost);

  // One process-lifetime agent: model, UI correlation state, and session
  // store remain stable across every submitted turn.
  const agent = await createAgent(config, onEvent, onUiRender, onUiRequest);

  editor.onSubmit = async (prompt) => {
    if (inTurn) {
      throw new Error("editor submitted while a turn is already running");
    }

    // Slash dispatch.
    if (prompt.startsWith("/")) {
      const handled = dispatchSlash(prompt.trim(), {
        transcript: transcriptContainer,
        tui,
        shutdown: () => requestShutdown(0),
      });
      if (handled) {
        editor.setText("");
        return;
      }
    }

    // Normal turn.
    inTurn = true;
    editor.disableSubmit = true;
    editor.setText("");

    // Echo user prompt + reset streaming state.
    const userEcho = new UserMessage(prompt);
    transcriptContainer.addChild(userEcho);
    tui.requestRender();

    try {
      await runTurn(agent, prompt, sessionId);
      // After turn_completed (handled by router), nothing else to do.
    } catch (e: any) {
      const msg = e && typeof e === "object" && e.message ? e.message : String(e);
      transcriptContainer.addChild(errorNotice(msg));
      tui.requestRender();
    } finally {
      inTurn = false;
      editor.disableSubmit = false;
      statusLoader.stop();
      tui.requestRender();
    }
  };

  // ----- Shutdown --------------------------------------------------------
  let shutdownPromise: Promise<void> | undefined;
  const shutdown = (): Promise<void> => {
    if (shutdownPromise !== undefined) return shutdownPromise;
    shutdownPromise = (async () => {
      uiRequestOverlay.cancel();
      try {
        await shutdownAgent(agent);
      } finally {
        uiRenderHost.dispose();
        tui.stop();
      }
    })();
    return shutdownPromise;
  };
  const requestShutdown = (successCode: number): void => {
    void shutdown().then(
      () => process.exit(successCode),
      (error: unknown) => {
        console.error("cetas-js shutdown failed", error);
        process.exit(1);
      },
    );
  };
  process.on("SIGINT", () => requestShutdown(0));
  tui.addInputListener((data) => {
    // Overlay dismiss: any key closes an active overlay before anything else.
    if (tui.hasOverlay()) {
      if (uiRequestOverlay.isActive()) return undefined;
      tui.hideOverlay();
      return { consume: true };
    }
    if (matchesKey(data, "ctrl+c")) {
      requestShutdown(0);
      return { consume: true };
    }
    return undefined;
  });

  tui.start();
}

// ---------------------------------------------------------------------------
// Slash command dispatch (C.8) — simple if-chain.
// ---------------------------------------------------------------------------

interface SlashContext {
  transcript: Container;
  tui: TUI;
  shutdown(): void;
}

function dispatchSlash(input: string, ctx: SlashContext): boolean {
  const spaceIdx = input.indexOf(" ");
  const cmd = spaceIdx === -1 ? input : input.slice(0, spaceIdx);

  if (cmd === "/help" || cmd === "/?") {
    const lines = [
      theme.brandBold("Slash Commands"),
      "",
      `  ${theme.accent("/help")}     Show this help`,
      `  ${theme.accent("/clear")}    Clear transcript`,
      `  ${theme.accent("/exit")}     Quit cetas-js`,
      "",
      theme.muted("Press any key to close"),
    ];
    const overlayContent = new Container();
    for (const line of lines) {
      overlayContent.addChild(new Text(line, 2, 0));
    }
    ctx.tui.showOverlay(overlayContent, { width: "60%", anchor: "center" });
    return true;
  }

  if (cmd === "/clear") {
    ctx.transcript.clear();
    for (const c of banner("cetas-js", "transcript cleared")) {
      ctx.transcript.addChild(c);
    }
    ctx.tui.requestRender();
    return true;
  }

  if (cmd === "/exit" || cmd === "/quit") {
    ctx.shutdown();
    return true;
  }

  // Unknown — show error.
  ctx.transcript.addChild(
    new Text(
      theme.error(`✗ Unknown command: ${cmd}`) +
        "\n  " +
        theme.muted("Type /help for the list."),
      1,
      0,
    ),
  );
  ctx.tui.requestRender();
  return true;
}

void main().catch((error: unknown) => {
  console.error("cetas-js fatal error", error);
  process.exit(1);
});
