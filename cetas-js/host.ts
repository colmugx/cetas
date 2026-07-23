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

import { CetasJsConfig, cetas_js_run_turn } from "../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";
import { parseCetasEvent, type CetasEvent } from "./src/events.ts";
import {
  registerBuiltinToolRenderers,
} from "./src/tool-renderers/index.ts";
import {
  UserMessage,
  errorNotice,
} from "./src/transcript/components.ts";
import { EventRouter } from "./src/controllers/event-router.ts";
import { theme, markdownTheme } from "./ui/theme.ts";
import { blankLine, banner } from "./ui/primitives.ts";
import { DebugFooter, defaultDebugInfo } from "./ui/layout.ts";

// ---------------------------------------------------------------------------
// MoonBit FFI shapes — positional constructor, async run_turn.
// ---------------------------------------------------------------------------

type CetasJsRunTurn = (
  config: unknown,
  observerCallback: (eventJson: string) => void,
  prompt: string,
  sessionId: string,
) => Promise<string>;

const runTurn = cetas_js_run_turn as unknown as CetasJsRunTurn;

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
  tui.addChild(statusWrapper);

  // editor
  const editor = new Editor(tui, editorTheme);
  tui.addChild(editor);
  tui.setFocus(editor);

  // footer — model + debug info bar
  const debugState = defaultDebugInfo(model);
  const footer = new DebugFooter(model);
  tui.addChild(footer);

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
    let parsed: unknown;
    try {
      parsed = JSON.parse(eventJson);
    } catch {
      // Malformed JSON from the bridge — log and move on. We don't want a
      // wire bug to kill the user's in-flight turn.
      return;
    }
    const ev = parseCetasEvent(parsed) as CetasEvent | null;
    if (!ev) return;

    // Track debug counters for the footer.
    switch (ev.type) {
      case "turn_started":
        turnStartTime = Date.now();
        debugState.turnCount++;
        debugState.toolsThisTurn = 0;
        debugState.tokensInput = 0;
        debugState.tokensOutput = 0;
        debugState.latencyMs = 0;
        debugState.sessionId = ev.session_id;
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

  editor.onSubmit = async (prompt) => {
    if (inTurn) return; // ignore re-entrancy — single in-flight turn

    // Slash dispatch.
    if (prompt.startsWith("/")) {
      const handled = dispatchSlash(prompt.trim(), {
        transcript: transcriptContainer,
        tui,
      });
      if (handled) {
        editor.setText("");
        return;
      }
    }

    // Normal turn.
    inTurn = true;
    editor.setText("");

    // Echo user prompt + reset streaming state.
    const userEcho = new UserMessage(prompt);
    transcriptContainer.addChild(userEcho);
    tui.requestRender();

    try {
      await runTurn(config, onEvent, prompt, "cetas-js-session");
      // After turn_completed (handled by router), nothing else to do.
    } catch (e: any) {
      const msg = e && typeof e === "object" && e.message ? e.message : String(e);
      transcriptContainer.addChild(errorNotice(msg));
      tui.requestRender();
    } finally {
      inTurn = false;
      statusLoader.stop();
      tui.requestRender();
    }
  };

  // ----- Shutdown --------------------------------------------------------
  process.on("SIGINT", () => {
    tui.stop();
    process.exit(0);
  });
  tui.addInputListener((data) => {
    // Overlay dismiss: any key closes an active overlay before anything else.
    if (tui.hasOverlay()) {
      tui.hideOverlay();
      return { consume: true };
    }
    if (matchesKey(data, "ctrl+c")) {
      tui.stop();
      process.exit(0);
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
}

function dispatchSlash(input: string, ctx: SlashContext): boolean {
  // Split into command + remainder.
  const spaceIdx = input.indexOf(" ");
  const cmd = spaceIdx === -1 ? input : input.slice(0, spaceIdx);
  const rest = spaceIdx === -1 ? "" : input.slice(spaceIdx + 1);

  if (cmd === "/help" || cmd === "/?") {
    const lines = [
      theme.brandBold("Slash Commands"),
      "",
      `  ${theme.accent("/help")}     Show this help`,
      `  ${theme.accent("/clear")}    Clear transcript`,
      `  ${theme.accent("/compact")}  (planned) Compress context`,
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

  if (cmd === "/compact") {
    // Planned — posoco has a Compressor port but cetas-core doesn't expose
    // a manual trigger yet. Surface as a system notice.
    ctx.transcript.addChild(
      new Text(
        theme.warning("⏳ /compact is not wired yet (posoco Compressor port is available; cetas-core trigger pending)."),
        1,
        0,
      ),
    );
    ctx.tui.requestRender();
    return true;
  }

  if (cmd === "/exit" || cmd === "/quit") {
    ctx.tui.stop();
    process.exit(0);
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
  // `rest` is unused for unknown commands but reserved for future args.
  void rest;
  return true;
}

main();
