/**
 * pi-tui adapter for cetas-js.
 *
 * This module owns terminal layout, input routing, slash interaction, and
 * rendering of provider-neutral application/events. The application itself
 * remains in `src/app`; this shell never resolves providers, endpoints, or
 * credentials and only invokes the application command boundary.
 */

import chalk from "chalk";
import { existsSync, readFileSync } from "node:fs";
import {
  Container,
  Editor,
  Loader,
  SelectList,
  Text,
  TUI,
  type Component,
  type EditorTheme,
  type OverlayHandle,
  type SelectListTheme,
} from "@earendil-works/pi-tui";
import { isKeyRelease, matchesKey, type KeyId } from "@earendil-works/pi-tui";

import {
  CetasApplication,
  type AgentCallbacks,
  type AppSnapshot,
  type CetasHostConfig,
  type ProviderAuthCapability,
} from "../src/app/index.ts";
import { newSessionId, sessionFilePath } from "../src/app/session-id.ts";
import { parseSessionReplay, type ReplayItem } from "../src/transcript/replay.ts";
import {
  listRewindPoints,
  readUserMessage,
  type RewindPoint,
} from "../src/transcript/rewind-points.ts";
import {
  parseCetasEvent,
  type CetasEvent,
} from "../src/events.ts";
import {
  hasImageMention,
  resolveImageAttachments,
  type ImageAttachment,
} from "../src/app/image-attachments.ts";
import { EventRouter } from "../src/controllers/event-router.ts";
import {
  errorNotice,
  systemNotice,
  AssistantMessage,
  QueuedUserMessage,
  ToolRow,
  UserMessage,
} from "../src/transcript/components.ts";
import { ThinkingComponent } from "../src/transcript/thinking.ts";
import { UiRegistry } from "../src/ui-registry.ts";
import { registerBuiltinToolRenderers } from "../src/tool-renderers/index.ts";
import {
  UiRenderHost,
  UiRequestBar,
  createUiRenderCallback,
  createUiRequestCallback,
} from "./extension-ui.ts";
import { CommandLock } from "./command-lock.ts";
import { banner } from "./primitives.ts";
import { ModelPickerOverlay, parseModelPickerOutcome, type ModelSelection } from "./model-picker.ts";
import {
  SkillsOverlay,
  parseSkillActivation,
  parseSkillsOutcome,
} from "./skills-overlay.ts";
import { OAuthOverlay } from "./oauth-overlay.ts";
import { AuthPromptOverlay, parseAuthPromptRequest } from "./auth-prompt-overlay.ts";
import { SessionsOverlay, listSessionEntries } from "./sessions-overlay.ts";
import { RewindOverlay } from "./rewind-overlay.ts";
import { translateSelectArrows } from "./select-nav.ts";
import { theme } from "./theme.ts";

const identity = (value: string): string => value;

/**
 * TUI keybinding and input conventions, surfaced through the forme
 * extension's /help command. Lives here because only the shell knows its own
 * keys; the host passes it into the agent config as the help note.
 */
export const CETAS_TUI_HELP_NOTE = [
  "During a turn:",
  "  ESC — interrupt the running turn (denies a pending approval first)",
  "  double-ESC while idle — first press clears the input, second opens /rewind",
  "  Typing while a turn runs stays live; Enter queues it as a follow-up",
  "  @path — autocomplete a workspace file (Tab/Enter applies it; the agent reads it)",
  "  /permission <mode> works mid-turn (readonly | workspace_write | interactive | yolo)",
  "  ctrl+t — collapse/expand thinking blocks",
  "  ctrl+o — collapse/expand tool output",
].join("\n");

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

export interface TerminalShellOptions {
  tui: TUI;
  cwd: string;
  /** Project sessions directory — `<home>/.cetas/sessions/--<encoded-cwd>--`. */
  sessionsDir: string;
  maxToolRounds: number;
  initialSessionId: string;
  /** Tool name → extension id (bridge tool catalog); labels tool rows. */
  toolLabels?: ReadonlyMap<string, string>;
  /** Host-owned process exit hook; tests can leave it undefined. */
  onExit?: (code: number) => void;
}

/** `posoco_ext_nowledge_mem` → `nowledge-mem`; foreign ids pass through. */
function displayExt(id: string): string {
  if (!id.startsWith("posoco_ext_")) return id;
  return id.slice("posoco_ext_".length).replace(/_/g, "-");
}

/**
 * Row title for a tool: `ext:tool_name` when the owning extension's display
 * name differs from the tool name; the bare `tool_name` otherwise (builtin
 * `posoco_ext_read` owns `read` — that must not render as `read:read`) and
 * when the catalog has no entry for the tool.
 */
export function toolDisplayLabel(
  extId: string | undefined,
  toolName: string,
): string {
  if (extId === undefined) return toolName;
  const display = displayExt(extId);
  return display === toolName ? toolName : `${display}:${toolName}`;
}

interface CommandOutcome {
  type: "success" | "failure" | "needs_input";
  feedback?: string;
  structured?: unknown;
  reason?: string;
  prompt?: string;
  ui_hint?: string;
}

class DismissibleTextOverlay implements Component {
  constructor(private readonly text: Text, private readonly close: () => void) {}

  render(width: number): string[] {
    return this.text.render(width);
  }

  handleInput(_data: string): void {
    this.close();
  }

  invalidate(): void {
    this.text.invalidate();
  }
}

class ProviderPickerOverlay implements Component {
  focused = false;

  constructor(
    private readonly title: Text,
    private readonly list: SelectList,
  ) {}

  render(width: number): string[] {
    return [...this.title.render(width), ...this.list.render(width)];
  }

  handleInput(data: string): void {
    this.list.handleInput(translateSelectArrows(data));
  }

  invalidate(): void {
    this.title.invalidate();
    this.list.invalidate();
  }
}

/**
 * All terminal side effects live behind this class. `host.ts` only constructs
 * the bridge/application and delegates callbacks here.
 */
export class TerminalShell {
  readonly tui: TUI;
  readonly callbacks: AgentCallbacks;

  private app?: CetasApplication;
  private sessionId: string;
  private readonly cwd: string;
  private readonly sessionsDir: string;
  private readonly onExit: (code: number) => void;

  private readonly transcript: Container;
  private readonly statusLoader: Loader;
  private readonly statusWrapper: Container;
  private readonly setupStatus: Container;
  private readonly extensionStatus: Container;
  private readonly extensionWidgets: Container;
  private readonly editor: Editor;
  private readonly statusBarMount: Container;
  private readonly router: EventRouter;
  private readonly uiRenderHost: UiRenderHost;
  private readonly uiRequestBar: UiRequestBar;
  private readonly uiRegistry = new UiRegistry();
  private readonly modelPicker: ModelPickerOverlay;
  private readonly oauthOverlay: OAuthOverlay;
  private readonly authPromptOverlay: AuthPromptOverlay;
  private readonly skillsOverlay: SkillsOverlay;
  private readonly sessionsOverlay: SessionsOverlay;
  private readonly rewindOverlay: RewindOverlay;
  /** Replay: tool-call rows awaiting their result line during resume. */
  private readonly replayedToolRows = new Map<string, ToolRow>();
  /** Lazily fetched once: the skills catalog is snapshotted at agent composition. */
  private skillsAutocompleteItems?: ReadonlyArray<{ label: string; detail: string; insert_text: string }>;
  /** Workspace file index for `@` mentions; TTL-cached because the walk is bounded but not free. */
  private fileIndexItems?: readonly string[];
  private fileIndexLoadedAt = 0;

  private inTurn = false;
  private commandBusy = false;
  /** Timestamp of the last idle ESC — arms the double-press rewind window. */
  private lastEscapeAt?: number;
  /**
   * Single command-busy gate for every local command flow. An empty label
   * arms the gate without touching the status line (picker/session flows
   * never showed one); runLogin re-acquires under the provider picker, which
   * the lock tolerates by re-arming. Release is idempotent, so overlay
   * close/select callbacks and finally blocks can never double-release.
   */
  private readonly commandLock: CommandLock;
  /** ctrl+o state — persists across messages; new tool rows inherit it. */
  private toolOutputExpanded = false;
  /** Follow-up bubbles awaiting their TurnStarted; promoted oldest-first. */
  private readonly queuedPrompts: QueuedUserMessage[] = [];
  private commandShortcuts: ReadonlyArray<{ keyId: KeyId; command: string }> = [];
  private providerPickerHandle?: OverlayHandle;
  private started = false;
  private setupNoticeShown = false;
  private setupErrorShown?: string;
  private shutdownPromise?: Promise<void>;
  /**
   * Bridge events the lenient parser skipped since the last turn_started.
   * Grows in-memory across skips within one turn window.
   */
  private skippedBridgeEvents = 0;
  /** Whether this turn window already rendered the single skip notice. */
  private skippedEventsNoticed = false;

  constructor(options: TerminalShellOptions) {
    if (options.initialSessionId.length === 0) {
      throw new Error("initial session id must not be empty");
    }
    if (!Number.isSafeInteger(options.maxToolRounds) || options.maxToolRounds < 0) {
      throw new Error("maxToolRounds must be a non-negative integer (0 = unbounded)");
    }
    this.tui = options.tui;
    this.cwd = options.cwd;
    this.sessionsDir = options.sessionsDir;
    this.sessionId = options.initialSessionId;
    this.onExit = options.onExit ?? (() => {});
    this.callbacks = {
      observerCallback: (eventJson) => this.handleObserverEvent(eventJson),
      renderCallback: (eventJson) => this.handleUiRender(eventJson),
      requestCallback: (eventJson) => this.handleUiRequest(eventJson),
    };

    registerBuiltinToolRenderers();
    this.tui.setClearOnShrink(false);
    this.tui.addChild(new Text(theme.brandBold(" Welcome to Cetas"), 1, 0));

    this.transcript = new Container();
    this.tui.addChild(this.transcript);

    this.statusLoader = new Loader(
      this.tui,
      (value) => theme.accent(value),
      (value) => theme.muted(value),
      "",
    );
    this.statusWrapper = new Container();
    this.setupStatus = new Container();
    this.extensionStatus = new Container();
    const statusRegion = new Container();
    statusRegion.addChild(this.statusWrapper);
    statusRegion.addChild(this.setupStatus);
    statusRegion.addChild(this.extensionStatus);
    this.tui.addChild(statusRegion);

    this.extensionWidgets = new Container();
    this.tui.addChild(this.extensionWidgets);

    // Interactive asks (permission approval, extension questions) render
    // inline here — directly above the editor — instead of a centered
    // overlay that fights the streaming transcript for the same rows.
    const askRegion = new Container();
    this.tui.addChild(askRegion);

    this.editor = new Editor(this.tui, editorTheme);
    this.editor.setAutocompleteProvider(this.uiRegistry);
    this.tui.addChild(this.editor);
    this.tui.setFocus(this.editor);

    // The status bar is data-driven: ext-statusbar pushes `status:statusbar`
    // renders and this host mounts them below the editor as a single line.
    this.statusBarMount = new Container();
    this.tui.addChild(this.statusBarMount);

    this.uiRenderHost = new UiRenderHost(
      this.tui,
      {
        status: this.extensionStatus,
        notice: this.transcript,
        widget: this.extensionWidgets,
      },
      {
        "status:statusbar": { mount: this.statusBarMount, format: "line" },
      },
    );
    this.uiRequestBar = new UiRequestBar(this.tui, askRegion, () => {
      this.tui.setFocus(this.editor);
    });
    this.modelPicker = new ModelPickerOverlay(this.tui);
    this.oauthOverlay = new OAuthOverlay(this.tui, () => {
      this.app?.cancelCurrentOperation();
    });
    this.authPromptOverlay = new AuthPromptOverlay(this.tui);
    this.skillsOverlay = new SkillsOverlay(this.tui);
    this.sessionsOverlay = new SessionsOverlay(this.tui);
    this.rewindOverlay = new RewindOverlay(this.tui);
    this.commandLock = new CommandLock(
      (label) => {
        this.commandBusy = true;
        this.editor.disableSubmit = true;
        if (label.length > 0) this.setCommandStatus(label);
      },
      () => this.finishCommand(),
    );

    this.router = new EventRouter({
      addTranscriptChild: (component) => this.addTranscriptChild(component),
      setStatus: (kind, message) => this.setTurnStatus(kind, message),
      requestRender: () => this.tui.requestRender(),
      cwd: this.cwd,
      toolLabel: (name) => toolDisplayLabel(options.toolLabels?.get(name), name),
      initialToolExpanded: () => this.toolOutputExpanded,
      onSessionRedirect: (_from, to) => {
        // Follow the redirect immediately so later prompts target the new
        // thread, and adopt it at the app boundary as an observed runtime
        // fact — adoptSessionRedirect carries no running-operation guards,
        // unlike setSession. `app` may be undefined pre-attach.
        this.sessionId = to;
        try {
          this.app?.adoptSessionRedirect(to);
        } catch (error: unknown) {
          this.addTranscriptChild(
            systemNotice(`session switch deferred: ${errorMessage(error)}`),
          );
        }
      },
    });

    this.tui.addInputListener((data) => this.handleInput(data));
    this.editor.onSubmit = (prompt) => {
      void this.submit(prompt).catch((error) =>
        this.addTranscriptChild(errorNotice(errorMessage(error))),
      );
    };
    this.registerAutocomplete();
  }

  attachApplication(app: CetasApplication): void {
    if (this.app !== undefined) throw new Error("cetas application is already attached");
    this.app = app;
    // The host attaches before app.start() composes the agent, so this first
    // pass only sees the hardcoded entries; handleSnapshot refreshes once the
    // bridge catalog (with extension shortcuts) exists.
    this.refreshCommandShortcuts();
  }

  /** Start application discovery and then enter pi-tui's render loop. */
  async start(): Promise<AppSnapshot | undefined> {
    if (this.started) throw new Error("terminal shell is already started");
    const app = this.requireApp();
    let snapshot: AppSnapshot | undefined;
    try {
      snapshot = await app.start();
      this.handleSnapshot(snapshot);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.addTranscriptChild(errorNotice(message));
      this.handleSnapshot(app.snapshot());
      // Keep the shell alive so users can repair settings and retry `/login`.
      console.error("cetas-js setup failed", error);
    }
    // Providers whose catalog build failed are skipped, not fatal: tell the
    // user which ones are missing so the settings can be repaired while the
    // healthy providers keep working.
    for (const warning of app.snapshot().setup.warnings ?? []) {
      this.addTranscriptChild(systemNotice(`⚠ ${warning}`));
    }
    this.started = true;
    this.tui.start();
    this.tui.requestRender(true);
    return snapshot;
  }

  async submit(prompt: string): Promise<void> {
    if (this.commandBusy) {
      throw new Error("editor submitted while a command is running");
    }
    const trimmed = prompt.trim();
    this.editor.setText("");
    if (trimmed.startsWith("/")) {
      try {
        await this.dispatchSlash(trimmed);
      } catch (error: unknown) {
        this.addTranscriptChild(errorNotice(`${trimmed} failed: ${errorMessage(error)}`));
      }
      return;
    }
    if (trimmed.startsWith("$")) {
      try {
        await this.submitSkillMention(trimmed);
      } catch (error: unknown) {
        this.addTranscriptChild(errorNotice(`${trimmed} failed: ${errorMessage(error)}`));
      }
      return;
    }
    if (trimmed.length === 0) return;

    const app = this.requireApp();
    const { images, paths } = await this.resolveImageMentions(app, trimmed);
    if (this.inTurn) {
      this.queueDuringTurn(app, trimmed, images);
      return;
    }
    await this.runTurnAndRender(app, trimmed, new UserMessage(trimmed, paths), images);
  }

  /**
   * `@path` image mentions become inline attachments, gated on the active
   * model's `image_in` capability: an image-incapable model attaches nothing
   * and gets a visible warning (Codex-style attach-time gate) instead of a
   * request the encoder must downgrade. Resolution problems are warnings,
   * never submit failures — the text mention always goes out.
   */
  private async resolveImageMentions(
    app: CetasApplication,
    prompt: string,
  ): Promise<{ images: ImageAttachment[]; paths: string[] }> {
    if (!hasImageMention(prompt)) return { images: [], paths: [] };
    if (!app.supportsImageInput()) {
      this.addTranscriptChild(
        systemNotice(
          "⚠ the active model does not accept image input; @image mentions were not attached (switch with /model)",
        ),
      );
      return { images: [], paths: [] };
    }
    const resolution = await resolveImageAttachments(prompt, this.cwd, () =>
      app.listWorkspaceFiles(),
    );
    for (const warning of resolution.warnings) {
      this.addTranscriptChild(systemNotice(`⚠ ${warning}`));
    }
    return { images: resolution.attachments, paths: resolution.paths };
  }

  /**
   * Drive one turn to completion. Typing stays live while it runs: Enter
   * queues a follow-up on the active run (`queueDuringTurn`), ESC interrupts.
   * An AbortError rejection means the user interrupted, not a failure.
   */
  private async runTurnAndRender(
    app: CetasApplication,
    prompt: string,
    echo: Component,
    images: readonly ImageAttachment[] = [],
  ): Promise<void> {
    this.inTurn = true;
    this.addTranscriptChild(echo);
    try {
      await app.runTurn(prompt, this.sessionId, images.length > 0 ? images : undefined);
    } catch (error: unknown) {
      if (isAbortError(error)) {
        this.addTranscriptChild(systemNotice("⏹ interrupted"));
      } else {
        const message = error instanceof Error ? error.message : String(error);
        this.addTranscriptChild(errorNotice(message));
      }
      this.tui.requestRender();
    } finally {
      this.inTurn = false;
      // A failed turn never reaches its next TurnStarted, so queued bubbles
      // would stay pending forever — promote whatever is left.
      while (this.queuedPrompts.length > 0) {
        this.queuedPrompts.shift()?.promote();
      }
      this.statusLoader.stop();
      this.tui.requestRender();
    }
  }

  /**
   * Enter during a running turn: queue the text as a follow-up on the active
   * run. The Agent drains queued messages one per turn boundary inside the
   * pending runTurn await; each drained turn's TurnStarted promotes one
   * bubble. `"stale"` (or the equivalent race) falls back to a fresh turn.
   */
  private queueDuringTurn(
    app: CetasApplication,
    prompt: string,
    images: readonly ImageAttachment[] = [],
  ): void {
    const bubble = new QueuedUserMessage(prompt);
    try {
      const outcome = app.queueFollowUp(
        prompt,
        images.length > 0 ? images : undefined,
      );
      if (outcome === "full") {
        this.addTranscriptChild(
          errorNotice("follow-up queue is full (64); wait for the turn to finish"),
        );
        return;
      }
      if (outcome === "stale") {
        void this.runTurnAndRender(app, prompt, new UserMessage(prompt), images);
        return;
      }
      this.queuedPrompts.push(bubble);
      this.addTranscriptChild(bubble);
    } catch (error: unknown) {
      if (app.appState !== "running") {
        void this.runTurnAndRender(app, prompt, new UserMessage(prompt), images);
        return;
      }
      this.addTranscriptChild(errorNotice(errorMessage(error)));
    }
  }

  requestShutdown(code = 0): void {
    void this.shutdown().then(
      () => this.onExit(code),
      (error: unknown) => {
        console.error("cetas-js shutdown failed", error);
        this.onExit(1);
      },
    );
  }

  async shutdown(): Promise<void> {
    if (this.shutdownPromise !== undefined) return this.shutdownPromise;
    this.shutdownPromise = (async () => {
      this.uiRequestBar.cancel();
      this.modelPicker.hide();
      this.oauthOverlay.hide();
      this.authPromptOverlay.hide();
      this.skillsOverlay.hide();
      this.rewindOverlay.hide();
      this.providerPickerHandle?.hide();
      this.providerPickerHandle = undefined;
      try {
        if (this.app !== undefined) await this.app.shutdown();
      } finally {
        this.uiRenderHost.dispose();
        if (this.started) this.tui.stop();
      }
    })();
    return this.shutdownPromise;
  }

  handleSnapshot(snapshot: AppSnapshot): void {
    this.setupStatus.clear();
    if (snapshot.state === "needs_setup") {
      this.setupStatus.addChild(
        new Text(
            theme.warning("⚠ setup required") +
            theme.muted(" — use /model or /login [provider] [method]"),
          1,
          0,
        ),
      );
      this.ensureSetupNotice(snapshot.error);
    }
    // Extension command shortcuts only exist after app.start() composed the
    // agent — attachApplication ran too early to see them.
    if (snapshot.state === "ready") this.refreshCommandShortcuts();
    this.tui.requestRender();
  }

  /**
   * Generic command shortcuts: any extension command that declares a pi-tui
   * key id (e.g. ext-plan's "shift+tab") becomes a live keybinding.
   */
  private refreshCommandShortcuts(): void {
    this.commandShortcuts = (this.app?.listCommands() ?? [])
      .filter((descriptor) => descriptor.visible && descriptor.shortcut !== undefined)
      .map((descriptor) => ({
        keyId: descriptor.shortcut as KeyId,
        command: `/${descriptor.id}`,
      }));
  }

  private requireApp(): CetasApplication {
    if (this.app === undefined) throw new Error("cetas application is not attached");
    return this.app;
  }

  private addTranscriptChild(component: Component): void {
    this.transcript.addChild(component);
    this.tui.requestRender();
  }

  private ensureSetupNotice(error?: string): void {
    if (this.setupNoticeShown && error === undefined) return;
    if (!this.setupNoticeShown) {
      this.addTranscriptChild(
        systemNotice(
          "No model provider configured. Use /model to inspect available slots or /login [provider] [method] to authenticate.",
        ),
      );
      this.setupNoticeShown = true;
    }
    if (error !== undefined && error !== this.setupErrorShown) {
      this.addTranscriptChild(errorNotice(`provider setup: ${error}`));
      this.setupErrorShown = error;
    }
  }

  private setTurnStatus(
    kind: "working" | "retry" | "compaction" | "idle",
    message?: string,
  ): void {
    if (kind === "idle") {
      if (!this.commandBusy) {
        this.statusWrapper.clear();
        this.statusLoader.stop();
      }
    } else {
      this.statusLoader.setMessage(message ?? "working");
      this.statusLoader.start();
      this.statusWrapper.clear();
      this.statusWrapper.addChild(this.statusLoader);
    }
    this.tui.requestRender();
  }

  private setCommandStatus(message: string): void {
    this.statusLoader.setMessage(message);
    this.statusLoader.start();
    this.statusWrapper.clear();
    this.statusWrapper.addChild(this.statusLoader);
    this.tui.requestRender();
  }

  private clearCommandStatus(): void {
    if (this.inTurn) return;
    this.statusWrapper.clear();
    this.statusLoader.stop();
    this.tui.requestRender();
  }

  private handleObserverEvent(eventJson: string): void {
    const outcome = parseCetasEventLenient(eventJson);
    if ("skipped" in outcome) {
      this.noteSkippedBridgeEvent(outcome.skipped, eventJson);
      return;
    }
    const event = outcome.event;
    if (event.type === "turn_started") {
      this.skippedBridgeEvents = 0;
      this.skippedEventsNoticed = false;
      this.promoteQueuedPrompt();
    }
    if (event.type === "custom" && this.commandBusy) {
      this.oauthOverlay.notify(event);
    }
    this.router.handleEvent(event);
  }

  /**
   * Visible degradation for bridge bytes we cannot parse (version skew, bad
   * payload): every skip is logged with a bounded payload, but at most one
   * transcript notice renders per turn window so a skewed MoonBit bundle
   * cannot flood the UI. The callback must never throw across the FFI.
   */
  private noteSkippedBridgeEvent(reason: string, eventJson: string): void {
    console.warn(`cetas: skipped bridge event (${reason}): ${boundedJson(eventJson)}`);
    this.skippedBridgeEvents += 1;
    if (this.skippedEventsNoticed) return;
    this.skippedEventsNoticed = true;
    const count = this.skippedBridgeEvents;
    this.addTranscriptChild(
      errorNotice(
        `⚠ skipped ${count} unrecognized bridge event${count === 1 ? "" : "s"} (last: ${reason})`,
      ),
    );
  }

  /** A drained follow-up's turn is starting: restyle the oldest queued bubble. */
  private promoteQueuedPrompt(): void {
    const bubble = this.queuedPrompts.shift();
    if (bubble === undefined) return;
    bubble.promote();
    this.tui.requestRender();
  }

  private handleUiRender(eventJson: string): void {
    createUiRenderCallback(this.uiRenderHost)(eventJson);
  }

  private handleUiRequest(eventJson: string): Promise<string> {
    let raw: unknown;
    try {
      raw = JSON.parse(eventJson);
    } catch {
      // Unparseable bytes: the guarded generic callback below answers a
      // malformed_request ui_response instead of throwing across the FFI.
      raw = undefined;
    }
    if (
      typeof raw === "object" &&
      raw !== null &&
      !Array.isArray(raw) &&
      (raw as Record<string, unknown>).type === "auth_prompt"
    ) {
      try {
        return this.authPromptOverlay.request(parseAuthPromptRequest(raw));
      } catch {
        // Malformed auth_prompt bytes must not reject the bridge promise;
        // fall through to the guarded generic ui request path.
      }
    }
    return createUiRequestCallback(this.uiRequestBar, 300_000)(eventJson);
  }

  private registerAutocomplete(): void {
    this.uiRegistry.register("cetas.host", {
      component_keys: [],
      autocomplete: [
        {
          trigger: "/",
          kind: "command",
          spanSpaces: true,
          fetch: (prefix, signal) => {
            if (signal.aborted) return [];
            // "cmd arg-prefix" (after the trigger "/"): complete the
            // argument against the command's declared choices instead of
            // the command name list.
            const spaceIndex = prefix.indexOf(" ");
            if (spaceIndex !== -1) {
              return this.commandArgItems(
                prefix.slice(0, spaceIndex),
                prefix.slice(spaceIndex + 1),
              );
            }
            const local = [
              ["/new", "Start a new session"],
              ["/sessions", "Browse and resume past sessions"],
              ["/rewind", "Rewind to an earlier message of this session"],
              ["/model", "Select a model and effort"],
              ["/skills", "Browse discovered agent skills by scope"],
              ["/login", "Authenticate with a provider (API key or OAuth)"],
              ["/exit", "Quit cetas-js"],
            ].map(([label, detail]) => ({
              label,
              detail,
              insert_text: label,
            }));
            // Local entries win over extension commands with the same id
            // (the router also contributes /model and /login); without this
            // filter the dropdown lists those commands twice.
            const localIds = new Set(local.map((item) => item.label));
            const extension = this.requireApp().listCommands()
              .filter((descriptor) => !localIds.has(`/${descriptor.id}`))
              .map((descriptor) => ({
                label: `/${descriptor.id}`,
                detail: descriptor.description || descriptor.label,
                insert_text: `/${descriptor.id}`,
              }));
            return [...local, ...extension].filter((item) =>
              item.label.slice(1).startsWith(prefix),
            );
          },
        },
        {
          // `$name` skill mention: candidates come from the composed skills
          // catalog (lazy, cached per process). Enter applies the mention
          // without submitting — the turn only starts on the next Enter.
          trigger: "$",
          kind: "custom",
          fetch: async (prefix, signal) => {
            if (signal.aborted) return [];
            const items = await this.loadSkillsAutocompleteItems();
            return items.filter((item) => item.insert_text.slice(1).startsWith(prefix));
          },
        },
        {
          // `@path` file mention: candidates are the bridge's workspace file
          // index (lazy, TTL-cached), ranked locally per keystroke. The path
          // stays plain text in the submitted prompt — the model opens it with
          // the read tool, guided by the system prompt.
          trigger: "@",
          kind: "file",
          fetch: async (prefix, signal) => {
            if (signal.aborted) return [];
            const entries = await this.loadFileIndex(signal);
            if (signal.aborted) return [];
            return rankFileMentionItems(entries, prefix).map((path) => {
              const isDir = path.endsWith("/");
              return {
                label: path,
                detail: isDir ? "directory" : "",
                insert_text: isDir ? `@${path}` : `@${path} `,
              };
            });
          },
        },
      ],
    });
    // The editor reads the provider's trigger characters once, at
    // setAutocompleteProvider time. Registering the `$` source above changed
    // the trigger set, so re-bind the provider or typing `$` never opens the
    // dropdown (only force/Tab completion would work).
    this.editor.setAutocompleteProvider(this.uiRegistry);
  }

  private handleInput(data: string): { consume?: boolean } | undefined {
    // Input listeners receive kitty-protocol release events unfiltered (the
    // TUI drops them only for the focused component), and matchesKey cannot
    // tell press from release — so one physical keypress would run this
    // handler twice: a single ESC satisfied the double-press rewind window,
    // and ctrl+t/ctrl+o toggled on and instantly back off. Consume releases:
    // a full press-release cycle counts as one key press.
    if (isKeyRelease(data)) {
      return { consume: true };
    }
    if (matchesKey(data, "ctrl+c")) {
      this.requestShutdown(0);
      return { consume: true };
    }
    // Interactive overlays must receive their own keyboard events. The old
    // host closed every overlay from this listener, making model selection
    // impossible as soon as pi-tui gained real focus-aware overlays.
    // uiRequestBar (permission approval ask) takes keyboard focus too —
    // Up/Down/Enter/ESC must reach its inline panel, otherwise the user is
    // stuck while a turn is parked in .wait().
    if (
      this.uiRequestBar.isActive() ||
      this.modelPicker.isActive ||
      this.oauthOverlay.isActive ||
      this.authPromptOverlay.isActive ||
      this.skillsOverlay.isActive ||
      this.sessionsOverlay.isActive ||
      this.rewindOverlay.isActive ||
      this.providerPickerHandle !== undefined
    ) {
      return undefined;
    }
    if (this.tui.hasOverlay()) {
      this.tui.hideOverlay();
      return { consume: true };
    }
    // ESC interrupts the active turn: the mailbox abort gives the loop its
    // clean Cancelled path and the turn's AbortController stops an in-flight
    // model request immediately.
    if (this.inTurn && matchesKey(data, "escape")) {
      this.app?.interruptActiveTurn();
      return { consume: true };
    }
    // Idle double-ESC (Gemini semantics): the first press clears a non-empty
    // editor, the second within the window opens the rewind picker. This sits
    // below every overlay check, so an overlay can never race it here.
    if (!this.inTurn && !this.commandBusy && matchesKey(data, "escape")) {
      const now = Date.now();
      if (this.editor.getText().length > 0) {
        this.editor.setText("");
        this.lastEscapeAt = now;
      } else if (shouldOpenRewindOnEscape(this.lastEscapeAt, now)) {
        this.lastEscapeAt = undefined;
        this.openRewindPicker();
      } else {
        this.lastEscapeAt = now;
      }
      return { consume: true };
    }
    // Global collapse toggles (pi keymap parity): usable in and out of turns,
    // but only after overlays had their chance above. Neither key is bound
    // in pi-tui's editor defaults, so interception shadows no editor behavior.
    if (matchesKey(data, "ctrl+t")) {
      this.toggleThinkingCollapsed();
      return { consume: true };
    }
    if (matchesKey(data, "ctrl+o")) {
      this.toggleToolOutputExpanded();
      return { consume: true };
    }
    // Typing during a turn stays live — keys flow to the focused editor so
    // Enter can queue follow-ups and /permission can switch modes. Only
    // command operations still swallow keys (their overlays own the flow).
    if (this.commandBusy) return { consume: true };
    // Extension-declared command shortcuts (e.g. shift+tab → /plan).
    if (!this.inTurn) {
      for (const binding of this.commandShortcuts) {
        if (matchesKey(data, binding.keyId)) {
          void this.invokeCommand(binding.command, "");
          return { consume: true };
        }
      }
    }
    return undefined;
  }

  /** ctrl+t — collapse/expand every finalized thinking block. */
  private toggleThinkingCollapsed(): void {
    for (const child of this.transcript.children) {
      if (child instanceof ThinkingComponent) child.toggleCollapsed();
    }
    this.tui.requestRender();
  }

  /** ctrl+o — collapse/expand every tool row; the state persists. */
  private toggleToolOutputExpanded(): void {
    this.toolOutputExpanded = !this.toolOutputExpanded;
    for (const child of this.transcript.children) {
      if (child instanceof ToolRow) child.setExpanded(this.toolOutputExpanded);
    }
    this.tui.requestRender();
  }

  private async dispatchSlash(input: string): Promise<void> {
    const spaceIndex = input.indexOf(" ");
    const command = spaceIndex === -1 ? input : input.slice(0, spaceIndex);
    const rawArgs = spaceIndex === -1 ? "" : input.slice(spaceIndex + 1).trim();

    const route = matchLocalSlash(command);
    if (route === undefined) {
      await this.invokeCommand(command, rawArgs);
      return;
    }
    await this.slashHandlers[route.id]?.(rawArgs);
  }

  /**
   * Per-route behavior for the local slash commands, keyed by route id.
   * The arg-empty checks for /model and /skills live here, not in the
   * matcher: "/model <args>" keeps its extension-command path through
   * invokeCommand.
   */
  private readonly slashHandlers: Readonly<
    Record<string, (rawArgs: string) => Promise<void> | void>
  > = {
    new: () => this.startNewSession(),
    sessions: () => this.openSessionsPicker(),
    rewind: () => this.openRewindPicker(),
    exit: () => this.requestShutdown(0),
    model: async (rawArgs) => {
      if (rawArgs.length === 0) {
        await this.openModelPicker();
        return;
      }
      await this.invokeCommand("/model", rawArgs);
    },
    skills: async (rawArgs) => {
      if (rawArgs.length === 0) {
        await this.openSkillsPicker();
        return;
      }
      await this.invokeCommand("/skills", rawArgs);
    },
    login: (rawArgs) => this.openLogin(rawArgs),
  };

  private async startNewSession(): Promise<void> {
    if (this.inTurn || this.commandBusy) {
      this.addTranscriptChild(errorNotice("/new cannot run while an operation is active"));
      return;
    }
    const nextSession = newSessionId();
    this.requireApp().setSession(nextSession);
    this.sessionId = nextSession;
    this.transcript.clear();
    for (const component of banner("cetas-js", "new session started")) {
      this.transcript.addChild(component);
    }
    this.tui.terminal.clearScreen();
    this.tui.requestRender(true);
  }

  private async openModelPicker(): Promise<void> {
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice("/model cannot run while another command is active"));
      return;
    }
    this.commandLock.acquire("loading model catalog");
    try {
      const outcome = parseModelPickerOutcome(
        await this.requireApp().invokeCommand("model", "{}"),
      );
      if (outcome.type !== "success") {
        this.renderOutcome(outcome, "/model");
        this.commandLock.release();
        return;
      }
      if (outcome.entries.length === 0) {
        this.addTranscriptChild(errorNotice("/model: provider returned an empty model catalog"));
        this.commandLock.release();
        return;
      }
      this.modelPicker.open(
        outcome.entries,
        (selection) => void this.applyModelSelection(selection),
        () => this.commandLock.release(),
      );
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/model failed: ${errorMessage(error)}`));
      this.commandLock.release();
    }
  }

  private async applyModelSelection(selection: ModelSelection): Promise<void> {
    this.setCommandStatus(`switching to ${selection.slot}`);
    try {
      const args = {
        slot: selection.slot,
        ...(selection.effort === undefined ? {} : { effort: selection.effort }),
      };
      const raw = await this.requireApp().invokeCommand("model", JSON.stringify(args));
      const outcome = parseModelPickerOutcome(raw);
      this.renderOutcome(outcome, "/model");
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/model failed: ${errorMessage(error)}`));
    } finally {
      this.commandLock.release();
    }
  }

  /**
   * `$name [task…]` — user-invoked skill activation. Activation loads the
   * SKILL.md body once (progressive disclosure) and embeds it in the turn's
   * user message; the transcript keeps showing the raw mention, not the
   * injected instructions. Runs as command (activation) then turn, which the
   * application state machine guarantees are mutually exclusive.
   */
  private async submitSkillMention(input: string): Promise<void> {
    const match = /^\$(\S+)(?:\s+([\s\S]*))?$/.exec(input);
    if (match === null) {
      this.addTranscriptChild(errorNotice("$ needs a skill name — type $ to browse skills, then $name to activate"));
      return;
    }
    const name = match[1] as string;
    const tail = (match[2] ?? "").trim();
    if (this.inTurn) {
      this.addTranscriptChild(errorNotice(`$${name} waits until the running turn ends`));
      return;
    }
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice(`$${name} cannot run while another command is active`));
      return;
    }
    this.commandLock.acquire(`activating skill ${name}`);
    let instructions: string | undefined;
    try {
      const outcome = parseSkillActivation(
        await this.requireApp().invokeCommand("skills", JSON.stringify({ action: "activate", name })),
      );
      if (outcome.type !== "success") {
        this.addTranscriptChild(errorNotice(`$${name}: ${outcome.reason}`));
        return;
      }
      instructions = outcome.instructions;
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`$${name} failed: ${errorMessage(error)}`));
      return;
    } finally {
      this.commandLock.release();
    }
    if (instructions === undefined) return;
    const prompt =
      `<activated-skill name="${escapeXml(name)}">\n${instructions}\n</activated-skill>\n\n` +
      (tail.length > 0 ? tail : "Follow the activated skill's instructions.");
    await this.runTurnAndRender(this.requireApp(), prompt, new UserMessage(input));
  }

  /** Display-only skills browser: catalog metadata + discovery scope. */
  private async openSkillsPicker(): Promise<void> {
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice("/skills cannot run while another command is active"));
      return;
    }
    this.commandLock.acquire("loading skills catalog");
    try {
      const outcome = parseSkillsOutcome(await this.requireApp().invokeCommand("skills", "{}"));
      if (outcome.type !== "success") {
        this.addTranscriptChild(
          errorNotice(`/skills: ${outcome.type === "failure" ? outcome.reason : outcome.prompt}`),
        );
        this.commandLock.release();
        return;
      }
      this.skillsOverlay.open(outcome.entries, () => this.commandLock.release());
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/skills failed: ${errorMessage(error)}`));
      this.commandLock.release();
    }
  }

  /**
   * `/sessions` — list this project's session transcripts and resume one.
   * Entries are stat metadata from the sessions directory; picking one
   * repoints the application at that session (the /new switch in reverse).
   * Prior history is not replayed into the transcript — the session store
   * feeds it to the model on the next turn.
   */
  private openSessionsPicker(): void {
    if (this.inTurn || this.commandBusy) {
      this.addTranscriptChild(errorNotice("/sessions cannot run while an operation is active"));
      return;
    }
    this.commandLock.acquire("");
    try {
      this.sessionsOverlay.open(
        listSessionEntries(this.sessionsDir, this.sessionId),
        (id) => this.resumeSession(id),
        () => this.commandLock.release(),
      );
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/sessions failed: ${errorMessage(error)}`));
      this.commandLock.release();
    }
  }

  /**
   * `/rewind` and the idle double-ESC gesture — list the current session's
   * user messages and truncate the transcript back to the chosen one. The
   * command lock covers the picker and the rewind itself, keeping submits
   * and other command flows out of the window.
   */
  private openRewindPicker(): void {
    if (this.inTurn || this.commandBusy) {
      this.addTranscriptChild(errorNotice("/rewind cannot run while an operation is active"));
      return;
    }
    const path = sessionFilePath(this.sessionsDir, this.sessionId);
    if (!existsSync(path)) {
      this.addTranscriptChild(
        systemNotice("nothing to rewind — this session has no transcript yet"),
      );
      return;
    }
    let jsonl: string;
    try {
      jsonl = readFileSync(path, "utf8");
    } catch (error: unknown) {
      this.addTranscriptChild(
        errorNotice(`/rewind: could not read the session transcript: ${errorMessage(error)}`),
      );
      return;
    }
    this.commandLock.acquire("");
    try {
      const points = listRewindPoints(jsonl);
      if (points.length === 0) {
        this.addTranscriptChild(
          systemNotice("nothing to rewind — no user messages in this session yet"),
        );
        this.commandLock.release();
        return;
      }
      this.rewindOverlay.open(
        points,
        (point) => void this.applyRewind(point),
        () => this.commandLock.release(),
      );
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/rewind failed: ${errorMessage(error)}`));
      this.commandLock.release();
    }
  }

  private async applyRewind(point: RewindPoint): Promise<void> {
    try {
      await this.requireApp().rewind(this.sessionId, point.messageIndex);
      this.transcript.clear();
      this.addTranscriptChild(
        systemNotice(
          `rewound to message #${point.messageIndex} — the original prompt is back in the editor`,
        ),
      );
      // Replay the truncated history so the screen matches what the model
      // will see (resumeSession's path); read errors render the notice only.
      let jsonl = "";
      try {
        jsonl = readFileSync(sessionFilePath(this.sessionsDir, this.sessionId), "utf8");
      } catch (error: unknown) {
        this.addTranscriptChild(
          errorNotice(`could not replay session history: ${errorMessage(error)}`),
        );
      }
      for (const component of this.replayComponents(parseSessionReplay(jsonl))) {
        this.addTranscriptChild(component);
      }
      // The picker's preview is truncated; refill from the full record so the
      // prompt can be edited and resubmitted.
      this.editor.setText(readUserMessage(jsonl, point.messageIndex) ?? "");
      this.tui.terminal.clearScreen();
      this.tui.requestRender(true);
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/rewind failed: ${errorMessage(error)}`));
    } finally {
      this.commandLock.release();
    }
  }

  private resumeSession(sessionId: string): void {
    // The overlay already closed before this callback runs; a throw here
    // would reach pi-tui's unguarded input dispatch and kill the process.
    try {
      if (sessionId === this.sessionId) {
        this.addTranscriptChild(systemNotice("already in this session"));
        return;
      }
      this.requireApp().setSession(sessionId);
      this.sessionId = sessionId;
      this.transcript.clear();
      for (const component of banner("cetas-js", `resumed session ${sessionId}`)) {
        this.transcript.addChild(component);
      }
      // Replay the persisted history into the view. The session store already
      // fed it to the model through setSession; this makes the screen match
      // what the model sees. Read errors and empty sessions render the banner
      // only — resume must not fail because a transcript is unreadable.
      try {
        const path = sessionFilePath(this.sessionsDir, sessionId);
        if (existsSync(path)) {
          const items = parseSessionReplay(readFileSync(path, "utf8"));
          for (const component of this.replayComponents(items)) {
            this.addTranscriptChild(component);
          }
        }
      } catch (error: unknown) {
        this.addTranscriptChild(
          errorNotice(`could not replay session history: ${errorMessage(error)}`),
        );
      }
      this.tui.terminal.clearScreen();
      this.tui.requestRender(true);
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`resume failed: ${errorMessage(error)}`));
    }
  }

  /** Turn replay items into the same components live turns render with. */
  private replayComponents(items: readonly ReplayItem[]): Component[] {
    const components: Component[] = [];
    for (const item of items) {
      switch (item.kind) {
        case "user": {
          const suffix = item.hasImage ? " 🖼" : "";
          const text = item.text.length === 0 ? "(image attachment)" : item.text;
          components.push(new UserMessage(text + suffix));
          break;
        }
        case "reasoning":
          components.push(new ThinkingComponent(item.text, "finalized"));
          break;
        case "assistant":
          components.push(new AssistantMessage(item.text));
          break;
        case "tool_call": {
          const row = new ToolRow(
            item.toolName,
            item.toolCallId,
            item.args,
            this.cwd,
            () => this.tui.requestRender(),
            toolDisplayLabel(undefined, item.toolName),
          );
          this.replayedToolRows.set(item.toolCallId, row);
          components.push(row);
          break;
        }
        case "tool_result": {
          // Results attach to their call's row when possible so output
          // collapses into the same line as the call; stray results (call in
          // an unreadable earlier record) stand alone.
          const row = this.replayedToolRows.get(item.toolCallId);
          if (row !== undefined) {
            row.setResult(item.content, item.isError, undefined);
            this.replayedToolRows.delete(item.toolCallId);
          } else {
            components.push(systemNotice(`[result] ${item.content}`));
          }
          break;
        }
      }
    }
    return components;
  }

  /**
   * `$`-mention autocomplete items. The catalog is discovery metadata
   * snapshotted at agent composition, so one successful fetch per process is
   * enough; failures are not cached so a later keystroke can retry.
   */
  private async loadSkillsAutocompleteItems(): Promise<
    ReadonlyArray<{ label: string; detail: string; insert_text: string }>
  > {
    if (this.skillsAutocompleteItems !== undefined) return this.skillsAutocompleteItems;
    try {
      const outcome = parseSkillsOutcome(await this.requireApp().invokeCommand("skills", "{}"));
      if (outcome.type !== "success") return [];
      const items = outcome.entries.map((entry) => ({
        label: `$${entry.name}`,
        detail: `[${entry.scope}] ${entry.description}`,
        insert_text: `$${entry.name}`,
      }));
      this.skillsAutocompleteItems = items;
      return items;
    } catch {
      return [];
    }
  }

  /**
   * `@`-mention candidate index. One bridge walk is cached for
   * `FILE_INDEX_TTL_MS`; a failed refresh (missing bridge support, walk
   * failure) keeps the previous snapshot so mid-keystroke dropdowns stay
   * stable instead of blinking empty.
   */
  private async loadFileIndex(signal: AbortSignal): Promise<readonly string[]> {
    const now = Date.now();
    if (
      this.fileIndexItems !== undefined &&
      now - this.fileIndexLoadedAt < FILE_INDEX_TTL_MS
    ) {
      return this.fileIndexItems;
    }
    try {
      const items = await this.requireApp().listWorkspaceFiles();
      if (signal.aborted) return this.fileIndexItems ?? [];
      this.fileIndexItems = items;
      this.fileIndexLoadedAt = now;
      return items;
    } catch {
      return this.fileIndexItems ?? [];
    }
  }

  private async openLogin(rawProvider: string): Promise<void> {
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice("/login cannot run while another command is active"));
      return;
    }
    const tokens = rawProvider.trim().length === 0 ? [] : rawProvider.trim().split(/\s+/);
    if (tokens.length > 2) {
      this.addTranscriptChild(errorNotice("/login accepts <provider> [method]"));
      return;
    }
    const capabilities = this.loginCapabilities();
    if (capabilities.length === 0) {
      // An empty capability snapshot means setup discovery has not completed
      // — precisely the state /login exists to recover from. An explicit
      // provider is validated by the bridge against the registered provider
      // factories, so it must not be gated on local capability data.
      if (tokens.length === 0) {
        this.addTranscriptChild(errorNotice("/login <provider> [method]: provider capabilities are unavailable until setup completes"));
        return;
      }
      await this.runLogin(tokens[0]!, tokens[1]);
      return;
    }
    if (tokens.length === 0) {
      if (capabilities.length === 1) {
        await this.chooseLoginMethod(capabilities[0]!);
      } else {
        this.showProviderPicker(capabilities);
      }
      return;
    }
    const provider = tokens[0]!;
    const capability = capabilities.find((entry) => entry.id === provider);
    if (capability === undefined) {
      this.addTranscriptChild(errorNotice(`/login: unknown authentication provider ${provider}`));
      return;
    }
    const method = tokens[1];
    if (method !== undefined) {
      if (!capability.methods.includes(method)) {
        this.addTranscriptChild(errorNotice(`/login: unsupported authentication method ${method} for ${provider}`));
        return;
      }
      await this.runLogin(provider, method);
    } else {
      await this.chooseLoginMethod(capability);
    }
  }

  /**
   * Argument completion after "/cmd ". Generic path completes the first
   * parameter that declares `choices` (e.g. /permission's action); `/login`
   * has no static choices and instead lists live providers, then the chosen
   * provider's methods.
   */
  private commandArgItems(
    command: string,
    argPrefix: string,
  ): Array<{ label: string; detail: string; insert_text: string }> {
    if (command === "login") return this.loginArgItems(argPrefix);
    const descriptor = this.requireApp()
      .listCommands()
      .find(
        (candidate) =>
          candidate.id === command || candidate.aliases.includes(command),
      );
    if (descriptor === undefined) return [];
    const param = descriptor.params.find(
      (candidate) => candidate.choices !== undefined,
    );
    if (param === undefined || param.choices === undefined) return [];
    return param.choices
      .filter((choice) => choice.startsWith(argPrefix))
      .map((choice) => ({
        label: choice,
        detail: `${descriptor.id} ${param.name} — ${param.description}`,
        insert_text: `/${descriptor.id} ${choice}`,
      }));
  }

  /** "/login [provider] [method]": provider ids first, then that provider's methods. */
  private loginArgItems(
    argPrefix: string,
  ): Array<{ label: string; detail: string; insert_text: string }> {
    const parts = argPrefix.split(/\s+/);
    if (parts.length <= 1) {
      const providerPrefix = parts[0] ?? "";
      return this.loginCapabilities()
        .filter((capability) => capability.id.startsWith(providerPrefix))
        .map((capability) => ({
          label: capability.id,
          detail: capability.methods.map(authMethodLabel).join(" / "),
          insert_text: `/login ${capability.id}`,
        }));
    }
    const providerId = parts[0] ?? "";
    const methodPrefix = parts[parts.length - 1] ?? "";
    const capability = this.loginCapabilities().find(
      (candidate) => candidate.id === providerId,
    );
    if (capability === undefined) return [];
    return capability.methods
      .filter((method) => method.startsWith(methodPrefix))
      .map((method) => ({
        label: method,
        detail: authMethodLabel(method),
        insert_text: `/login ${providerId} ${method}`,
      }));
  }

  private loginCapabilities(): readonly ProviderAuthCapability[] {
    const setup = this.requireApp().snapshot().setup;
    if (setup.authProviders !== undefined && setup.authProviders.length > 0) {
      return setup.authProviders;
    }
    const fromModels = new Map<string, Set<string>>();
    for (const model of setup.providers) {
      const methods = model.authMethods ?? (model.oauth ? ["oauth"] : []);
      const existing = fromModels.get(model.provider) ?? new Set<string>();
      for (const method of methods) existing.add(method);
      fromModels.set(model.provider, existing);
    }
    if (fromModels.size > 0) {
      return [...fromModels.entries()].map(([id, methods]) => ({ id, methods: [...methods] }));
    }
    return setup.oauthProviders.map((id) => ({ id, methods: ["oauth"] }));
  }

  private async chooseLoginMethod(capability: ProviderAuthCapability): Promise<void> {
    if (capability.methods.length === 0) {
      throw new Error(`authentication provider ${capability.id} advertises no methods`);
    }
    if (capability.methods.length === 1) {
      await this.runLogin(capability.id, capability.methods[0]!);
      return;
    }
    this.showAuthMethodPicker(capability);
  }

  private showProviderPicker(capabilities: readonly ProviderAuthCapability[]): void {
    this.commandLock.acquire("");
    const items = capabilities.map((capability) => ({
      value: capability.id,
      label: capability.id,
      description: capability.methods.map(authMethodLabel).join(" / "),
    }));
    const list = new SelectList(items, Math.min(8, items.length), selectListTheme);
    const panel = new ProviderPickerOverlay(
      new Text(theme.brandBold("Select authentication provider"), 1, 1),
      list,
    );
    let handle: OverlayHandle | undefined;
    const close = () => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      this.commandLock.release();
    };
    list.onSelect = (item) => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      const capability = capabilities.find((entry) => entry.id === item.value);
      if (capability === undefined) {
        this.commandLock.release();
        this.addTranscriptChild(errorNotice(`/login: unknown authentication provider ${item.value}`));
        return;
      }
      void this.chooseLoginMethod(capability).catch((error: unknown) => {
        this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
        this.commandLock.release();
      });
    };
    list.onCancel = close;
    try {
      handle = this.tui.showOverlay(panel, {
        width: "56%",
        maxHeight: "60%",
        anchor: "center",
        margin: 1,
      });
    } catch (error: unknown) {
      // The command lock is already held — release it or the terminal bricks.
      this.commandLock.release();
      this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
      return;
    }
    this.providerPickerHandle = handle;
    this.tui.requestRender();
  }

  private showAuthMethodPicker(capability: ProviderAuthCapability): void {
    this.commandLock.acquire("");
    const items = capability.methods.map((method) => ({
      value: method,
      label: authMethodLabel(method),
      description: method,
    }));
    const list = new SelectList(items, Math.min(8, items.length), selectListTheme);
    const panel = new ProviderPickerOverlay(
      new Text(theme.brandBold(`Select login method · ${capability.id}`), 1, 1),
      list,
    );
    let handle: OverlayHandle | undefined;
    const close = () => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      this.commandLock.release();
    };
    list.onSelect = (item) => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      void this.runLogin(capability.id, item.value).catch((error: unknown) => {
        this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
      });
    };
    list.onCancel = close;
    try {
      handle = this.tui.showOverlay(panel, {
        width: "62%",
        maxHeight: "60%",
        anchor: "center",
        margin: 1,
      });
    } catch (error: unknown) {
      // The command lock is already held — release it or the terminal bricks.
      this.commandLock.release();
      this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
      return;
    }
    this.providerPickerHandle = handle;
    this.tui.requestRender();
  }

  private async runLogin(provider: string, method?: string): Promise<void> {
    // Provider picker already owns the command lock; acquire tolerates that
    // nested re-acquire. Direct `/login p` takes the lock fresh here.
    this.commandLock.acquire(`authenticating ${provider}`);
    if (method === "oauth") this.oauthOverlay.show(provider);
    try {
      const raw = await this.requireApp().invokeCommand(
        "login",
        JSON.stringify({ provider, ...(method === undefined ? {} : { method }) }),
      );
      const outcome = parseCommandOutcome(raw);
      if (method === "oauth") {
        if (outcome.type === "success") {
          this.oauthOverlay.result(outcome.feedback ?? "login succeeded", false);
        } else if (outcome.type === "failure") {
          this.oauthOverlay.result(outcome.reason ?? "login failed", true);
        } else {
          this.oauthOverlay.result(outcome.prompt ?? "login needs input", true);
        }
      }
      this.renderOutcome(outcome, "/login");
    } catch (error: unknown) {
      const message = errorMessage(error);
      if (method === "oauth") this.oauthOverlay.result(message, true);
      this.addTranscriptChild(errorNotice(`/login failed: ${message}`));
    } finally {
      this.commandLock.release();
    }
  }

  private async invokeCommand(command: string, rawArgs: string): Promise<void> {
    if (command.length < 2 || !command.startsWith("/")) return;
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice(`${command} cannot run while another command is active`));
      return;
    }
    this.commandLock.acquire(`running ${command}`);
    try {
      const outcome = parseCommandOutcome(
        await this.requireApp().invokeCommand(command.slice(1), parsePositionalArgs(rawArgs, command)),
      );
      this.renderOutcome(outcome, command);
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`${command} failed: ${errorMessage(error)}`));
    } finally {
      this.commandLock.release();
    }
  }

  private renderOutcome(outcome: CommandOutcome, command: string): void {
    switch (outcome.type) {
      case "success":
        if (outcome.feedback !== undefined && outcome.feedback.length > 0) {
          this.addTranscriptChild(systemNotice(`${command}: ${outcome.feedback}`));
        }
        // These commands return structured data for pickers (slot catalog,
        // bar layout); the status bar already reflects it, so don't dump it.
        if (
          outcome.structured !== undefined &&
          !["/model", "/effort", "/statusbar"].includes(command)
        ) {
          this.addTranscriptChild(systemNotice(formatStructuredOutcome(outcome.structured)));
        }
        break;
      case "failure":
        this.addTranscriptChild(errorNotice(`${command}: ${outcome.reason ?? "failed"}`));
        break;
      case "needs_input":
        this.addTranscriptChild(systemNotice(`${command} needs input: ${outcome.prompt ?? ""}`));
        break;
    }
    this.tui.requestRender();
  }

  private finishCommand(): void {
    this.commandBusy = false;
    this.editor.disableSubmit = false;
    this.clearCommandStatus();
  }
}

/** How long one workspace walk serves `@`-mention queries before refresh. */
const FILE_INDEX_TTL_MS = 30_000;
const MAX_FILE_MENTION_ITEMS = 50;

/**
 * Rank `@`-mention candidates against the typed query (kimi-code-inspired):
 * basename exact > basename prefix > basename contains > full-path contains;
 * directories get +10 with a non-empty query; an empty query ranks by depth.
 * Non-matching entries drop out; ties break dirs-first, then path order.
 */
export function rankFileMentionItems(
  entries: readonly string[],
  query: string,
): string[] {
  const lowerQuery = query.toLowerCase();
  const scored: Array<{ path: string; score: number; isDir: boolean }> = [];
  for (const entry of entries) {
    const isDir = entry.endsWith("/");
    const clean = isDir ? entry.slice(0, -1) : entry;
    const base = clean.slice(clean.lastIndexOf("/") + 1).toLowerCase();
    const full = clean.toLowerCase();
    let score: number;
    if (lowerQuery.length === 0) {
      score = (isDir ? 120 : 100) - (clean.split("/").length - 1);
    } else if (base === lowerQuery) {
      score = 100;
    } else if (base.startsWith(lowerQuery)) {
      score = 80;
    } else if (base.includes(lowerQuery)) {
      score = 50;
    } else if (full.includes(lowerQuery)) {
      score = 30;
    } else {
      continue;
    }
    if (isDir && lowerQuery.length > 0) score += 10;
    scored.push({ path: entry, score, isDir });
  }
  scored.sort(
    (a, b) =>
      b.score - a.score ||
      Number(a.isDir) - Number(b.isDir) ||
      (a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
  );
  return scored.slice(0, MAX_FILE_MENTION_ITEMS).map((item) => item.path);
}

/** A slash command the shell handles locally instead of via extensions. */
export interface SlashRoute {
  id: string;
  aliases?: readonly string[];
}

const LOCAL_SLASH_ROUTES: readonly SlashRoute[] = [
  { id: "new" },
  { id: "sessions" },
  { id: "rewind" },
  { id: "exit", aliases: ["quit"] },
  { id: "model" },
  { id: "skills" },
  { id: "login" },
];

/**
 * Match a parsed command token ("/model") against the local slash routes.
 * Pure and case-sensitive ("/QUIT" stays unknown and reaches the extension
 * fallback); sees only the token, so argument logic stays in the handlers.
 */
export function matchLocalSlash(command: string): SlashRoute | undefined {
  return LOCAL_SLASH_ROUTES.find(
    (route) =>
      command === `/${route.id}` ||
      (route.aliases ?? []).some((alias) => command === `/${alias}`),
  );
}

export function parsePositionalArgs(raw: string, command = ""): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return "{}";
  if (command === "/model") {
    const parts = trimmed.split(/\s+/);
    if (parts.length === 1) return JSON.stringify({ slot: parts[0] });
    return JSON.stringify({ slot: parts[0], effort: parts.slice(1).join(" ") });
  }
  if (command === "/login") {
    const parts = trimmed.split(/\s+/);
    return JSON.stringify({
      provider: parts[0],
      ...(parts[1] === undefined ? {} : { method: parts[1] }),
    });
  }
  // Strict integer literal only — Number() would also accept "0x10"/"1e3",
  // which no session list ever produces as an index.
  if (/^-?\d+$/.test(trimmed)) {
    return JSON.stringify({ index: Number(trimmed) });
  }
  return JSON.stringify({ _positional: trimmed });
}

/** Double-press window for the idle ESC → rewind gesture, in ms. */
const REWIND_ESCAPE_WINDOW_MS = 500;

/**
 * Whether a second idle ESC opens the rewind picker: a previous ESC must be
 * recorded and `now` must fall inside the window after it (Gemini CLI's
 * useRepeatedKeyPress semantics). A backwards gap never counts. `now` is a
 * plain parameter so tests pin the clock.
 */
export function shouldOpenRewindOnEscape(
  lastEscapeAt: number | undefined,
  now: number,
  windowMs = REWIND_ESCAPE_WINDOW_MS,
): boolean {
  if (lastEscapeAt === undefined) return false;
  const elapsed = now - lastEscapeAt;
  return elapsed >= 0 && elapsed < windowMs;
}

function parseCommandOutcome(raw: string): CommandOutcome {
  const value: unknown = JSON.parse(raw);
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("command outcome must be an object");
  }
  const outcome = value as Record<string, unknown>;
  if (
    outcome.type !== "success" &&
    outcome.type !== "failure" &&
    outcome.type !== "needs_input"
  ) {
    throw new Error(`command outcome.type is unsupported: ${String(outcome.type)}`);
  }
  const result: CommandOutcome = { type: outcome.type };
  for (const key of ["feedback", "reason", "prompt", "ui_hint"] as const) {
    const item = outcome[key];
    if (item !== undefined) {
      if (typeof item !== "string") throw new Error(`command outcome.${key} must be a string`);
      result[key] = item;
    }
  }
  if ("structured" in outcome) result.structured = outcome.structured;
  return result;
}

function formatStructuredOutcome(value: unknown): string {
  if (Array.isArray(value)) {
    return value
      .map((entry) => {
        if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
          return `  ${JSON.stringify(entry)}`;
        }
        const record = entry as Record<string, unknown>;
        const marker = record.active === true ? "*" : " ";
        const label = typeof record.label === "string" ? record.label : String(record.id ?? "entry");
        const model = typeof record.model === "string" ? ` (${record.model})` : "";
        const efforts = Array.isArray(record.thinking_efforts)
          ? ` [effort: ${record.thinking_efforts.map(String).join(", ")}]`
          : "";
        return ` ${marker} ${label}${model}${efforts}`;
      })
      .join("\n");
  }
  return JSON.stringify(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Bound free-form bridge payloads for console logs (~200 chars). */
function boundedJson(value: string, max = 200): string {
  return value.length <= max ? value : `${value.slice(0, max)}…`;
}

/** The wire `type` tag of a parsed payload, bounded for short skip reasons. */
function eventTypeTag(parsed: unknown): string {
  if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
    const type = (parsed as Record<string, unknown>).type;
    if (typeof type === "string") return boundedJson(type, 80);
  }
  return "(no type)";
}

/**
 * FFI-safe event parse: never throws. JSON.parse failures, malformed known
 * types, and unknown type tags (TS/MoonBit version skew) all come back as a
 * short `skipped` reason so the observer callback can degrade visibly
 * instead of killing the turn.
 */
export function parseCetasEventLenient(
  rawJson: string,
): { event: CetasEvent } | { skipped: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch {
    return { skipped: "unparseable json" };
  }
  try {
    const event = parseCetasEvent(parsed);
    if (event === null) {
      return { skipped: `unknown type ${eventTypeTag(parsed)}` };
    }
    return { event };
  } catch {
    return { skipped: `malformed ${eventTypeTag(parsed)}` };
  }
}

/** Escape `& < > "` for safe XML embedding (skill names in prompts). */
function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * A turn interrupted via ESC. The bridge rejects in two shapes: from_async's
 * AbortError when the coroutine cancel surfaces directly, or — the common
 * path — a stringified `AgentError::<Kind>(... Cancelled ...)` because the
 * provider wraps the cancelled fetch as a transport failure. A bare
 * "Cancelled" substring is not enough: ordinary failures may carry that word.
 */
const AGENT_ERROR_CANCELLED = /AgentError::\w+\([^)]*Cancelled/;

export function isAbortError(error: unknown): boolean {
  if (error instanceof Error) {
    return error.name === "AbortError" || AGENT_ERROR_CANCELLED.test(error.message);
  }
  return typeof error === "string" && AGENT_ERROR_CANCELLED.test(error);
}

function authMethodLabel(method: string): string {
  switch (method) {
    case "api_key":
      return "API key";
    case "oauth":
      return "OAuth";
    default:
      return method;
  }
}
