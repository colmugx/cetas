/**
 * pi-tui adapter for cetas-js.
 *
 * This module owns terminal layout, input routing, slash interaction, and
 * rendering of provider-neutral application/events. The application itself
 * remains in `src/app`; this shell never resolves providers, endpoints, or
 * credentials and only invokes the application command boundary.
 */

import chalk from "chalk";
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
import { matchesKey, type KeyId } from "@earendil-works/pi-tui";

import {
  CetasApplication,
  type AgentCallbacks,
  type AppSnapshot,
  type CetasHostConfig,
  type ProviderAuthCapability,
} from "../src/app/index.ts";
import { parseCetasEvent } from "../src/events.ts";
import { EventRouter } from "../src/controllers/event-router.ts";
import {
  errorNotice,
  systemNotice,
  UserMessage,
} from "../src/transcript/components.ts";
import { UiRegistry } from "../src/ui-registry.ts";
import { registerBuiltinToolRenderers } from "../src/tool-renderers/index.ts";
import {
  UiRenderHost,
  UiRequestBar,
  createUiRenderCallback,
  createUiRequestCallback,
} from "./extension-ui.ts";
import { banner } from "./primitives.ts";
import { ModelPickerOverlay, parseModelPickerOutcome, type ModelSelection } from "./model-picker.ts";
import {
  SkillsOverlay,
  parseSkillActivation,
  parseSkillsOutcome,
} from "./skills-overlay.ts";
import { OAuthOverlay } from "./oauth-overlay.ts";
import { AuthPromptOverlay, parseAuthPromptRequest } from "./auth-prompt-overlay.ts";
import { theme } from "./theme.ts";

const identity = (value: string): string => value;

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
  maxToolRounds: number;
  initialSessionId: string;
  /** Host-owned process exit hook; tests can leave it undefined. */
  onExit?: (code: number) => void;
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
    this.list.handleInput(data);
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
  /** Lazily fetched once: the skills catalog is snapshotted at agent composition. */
  private skillsAutocompleteItems?: ReadonlyArray<{ label: string; detail: string; insert_text: string }>;

  private inTurn = false;
  private commandBusy = false;
  private commandShortcuts: ReadonlyArray<{ keyId: KeyId; command: string }> = [];
  private providerPickerHandle?: OverlayHandle;
  private started = false;
  private setupNoticeShown = false;
  private setupErrorShown?: string;
  private shutdownPromise?: Promise<void>;

  constructor(options: TerminalShellOptions) {
    if (options.initialSessionId.length === 0) {
      throw new Error("initial session id must not be empty");
    }
    if (!Number.isSafeInteger(options.maxToolRounds) || options.maxToolRounds < 0) {
      throw new Error("maxToolRounds must be a non-negative integer (0 = unbounded)");
    }
    this.tui = options.tui;
    this.cwd = options.cwd;
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

    this.router = new EventRouter({
      addTranscriptChild: (component) => this.addTranscriptChild(component),
      setStatus: (kind, message) => this.setTurnStatus(kind, message),
      requestRender: () => this.tui.requestRender(),
      cwd: this.cwd,
    });

    this.tui.addInputListener((data) => this.handleInput(data));
    this.editor.onSubmit = (prompt) => this.submit(prompt);
    this.registerAutocomplete();
  }

  attachApplication(app: CetasApplication): void {
    if (this.app !== undefined) throw new Error("cetas application is already attached");
    this.app = app;
    // Generic command shortcuts: any extension command that declares a
    // pi-tui key id (e.g. ext-plan's "shift+tab") becomes a live keybinding.
    this.commandShortcuts = app
      .listCommands()
      .filter((descriptor) => descriptor.visible && descriptor.shortcut !== undefined)
      .map((descriptor) => ({
        keyId: descriptor.shortcut as KeyId,
        command: `/${descriptor.id}`,
      }));
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
    if (this.inTurn || this.commandBusy) {
      throw new Error("editor submitted while another operation is running");
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
    if (prompt.length === 0) return;

    const app = this.requireApp();
    this.inTurn = true;
    this.editor.disableSubmit = true;
    this.addTranscriptChild(new UserMessage(prompt));
    try {
      await app.runTurn(prompt, this.sessionId);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.addTranscriptChild(errorNotice(message));
      this.tui.requestRender();
    } finally {
      this.inTurn = false;
      this.editor.disableSubmit = false;
      this.statusLoader.stop();
      this.tui.requestRender();
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
    this.tui.requestRender();
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
    const parsed: unknown = JSON.parse(eventJson);
    const event = parseCetasEvent(parsed);
    if (event === null) throw new Error("unknown or malformed cetas event");
    if (event.type === "custom" && this.commandBusy) {
      this.oauthOverlay.notify(event);
    }
    this.router.handleEvent(event);
  }

  private handleUiRender(eventJson: string): void {
    createUiRenderCallback(this.uiRenderHost)(eventJson);
  }

  private handleUiRequest(eventJson: string): Promise<string> {
    const raw: unknown = JSON.parse(eventJson);
    if (
      typeof raw === "object" &&
      raw !== null &&
      !Array.isArray(raw) &&
      (raw as Record<string, unknown>).type === "auth_prompt"
    ) {
      return this.authPromptOverlay.request(parseAuthPromptRequest(raw));
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
          fetch: (prefix, signal) => {
            if (signal.aborted) return [];
            const local = [
              ["/help", "Show slash commands"],
              ["/clear", "Clear the transcript"],
              ["/new", "Start a new session"],
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
      ],
    });
    // The editor reads the provider's trigger characters once, at
    // setAutocompleteProvider time. Registering the `$` source above changed
    // the trigger set, so re-bind the provider or typing `$` never opens the
    // dropdown (only force/Tab completion would work).
    this.editor.setAutocompleteProvider(this.uiRegistry);
  }

  private handleInput(data: string): { consume?: boolean } | undefined {
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
      this.providerPickerHandle !== undefined
    ) {
      return undefined;
    }
    if (this.tui.hasOverlay()) {
      this.tui.hideOverlay();
      return { consume: true };
    }
    // ESC interrupts the active turn: the application forwards an abort into
    // the run loop, which settles the turn with the transcript it already has.
    if (this.inTurn && matchesKey(data, "escape")) {
      this.app?.interruptActiveTurn();
      return { consume: true };
    }
    if (this.inTurn || this.commandBusy) return { consume: true };
    // Extension-declared command shortcuts (e.g. shift+tab → /plan).
    for (const binding of this.commandShortcuts) {
      if (matchesKey(data, binding.keyId)) {
        void this.invokeCommand(binding.command, "");
        return { consume: true };
      }
    }
    return undefined;
  }

  private async dispatchSlash(input: string): Promise<void> {
    const spaceIndex = input.indexOf(" ");
    const command = spaceIndex === -1 ? input : input.slice(0, spaceIndex);
    const rawArgs = spaceIndex === -1 ? "" : input.slice(spaceIndex + 1).trim();

    if (command === "/help" || command === "/?") {
      this.showHelp();
      return;
    }
    if (command === "/clear") {
      this.transcript.clear();
      for (const component of banner("cetas-js", "transcript cleared")) {
        this.transcript.addChild(component);
      }
      this.tui.terminal.clearScreen();
      this.tui.requestRender(true);
      return;
    }
    if (command === "/new") {
      if (this.inTurn || this.commandBusy) {
        this.addTranscriptChild(errorNotice("/new cannot run while an operation is active"));
        return;
      }
      const nextSession = `session-${Date.now()}`;
      this.requireApp().setSession(nextSession);
      this.sessionId = nextSession;
      this.transcript.clear();
      for (const component of banner("cetas-js", "new session started")) {
        this.transcript.addChild(component);
      }
      this.tui.terminal.clearScreen();
      this.tui.requestRender(true);
      return;
    }
    if (command === "/exit" || command === "/quit") {
      this.requestShutdown(0);
      return;
    }
    if (command === "/model" && rawArgs.length === 0) {
      await this.openModelPicker();
      return;
    }
    if (command === "/skills" && rawArgs.length === 0) {
      await this.openSkillsPicker();
      return;
    }
    if (command === "/login") {
      await this.openLogin(rawArgs);
      return;
    }
    await this.invokeCommand(command, rawArgs);
  }

  private showHelp(): void {
    const commands = [
      ["/help", "Show slash commands"],
      ["/clear", "Clear the transcript"],
      ["/new", "Start a new session"],
      ["/model", "List models, then choose model + effort"],
      ["/skills", "Browse discovered agent skills ($name activates one)"],
      ["/login [provider] [method]", "Authenticate with an API key or OAuth"],
      ["/exit", "Quit cetas-js"],
    ];
    const extensionLines = this.requireApp()
      .listCommands()
      .filter((descriptor) => !["model", "login"].includes(descriptor.id))
      .map((descriptor) => `  ${theme.accent(`/${descriptor.id}`)}  ${descriptor.description || descriptor.label}`);
    const lines = [
      theme.brandBold("Slash Commands"),
      "",
      ...commands.map(([name, description]) => `  ${theme.accent(name)}  ${description}`),
      ...(extensionLines.length === 0
        ? []
        : ["", theme.muted("Extension commands"), ...extensionLines]),
      "",
      theme.muted("Press any key to close"),
    ];
    const text = new Text(lines.join("\n"), 2, 1);
    let handle: OverlayHandle | undefined;
    const panel = new DismissibleTextOverlay(text, () => {
      handle?.hide();
      this.tui.requestRender();
    });
    handle = this.tui.showOverlay(panel, {
      width: "64%",
      maxHeight: "70%",
      anchor: "center",
      margin: 1,
    });
    this.tui.requestRender();
  }

  private async openModelPicker(): Promise<void> {
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice("/model cannot run while another command is active"));
      return;
    }
    this.commandBusy = true;
    this.editor.disableSubmit = true;
    this.setCommandStatus("loading model catalog");
    try {
      const outcome = parseModelPickerOutcome(
        await this.requireApp().invokeCommand("model", "{}"),
      );
      if (outcome.type !== "success") {
        this.renderOutcome(outcome, "/model");
        this.finishCommand();
        return;
      }
      if (outcome.entries.length === 0) {
        this.addTranscriptChild(errorNotice("/model: provider returned an empty model catalog"));
        this.finishCommand();
        return;
      }
      this.modelPicker.open(
        outcome.entries,
        (selection) => void this.applyModelSelection(selection),
        () => this.finishCommand(),
      );
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/model failed: ${errorMessage(error)}`));
      this.finishCommand();
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
      this.finishCommand();
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
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice(`$${name} cannot run while another command is active`));
      return;
    }
    this.commandBusy = true;
    this.editor.disableSubmit = true;
    this.setCommandStatus(`activating skill ${name}`);
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
      this.finishCommand();
    }
    if (instructions === undefined) return;
    const prompt =
      `<activated-skill name="${name}">\n${instructions}\n</activated-skill>\n\n` +
      (tail.length > 0 ? tail : "Follow the activated skill's instructions.");
    const app = this.requireApp();
    this.inTurn = true;
    this.editor.disableSubmit = true;
    this.addTranscriptChild(new UserMessage(input));
    try {
      await app.runTurn(prompt, this.sessionId);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.addTranscriptChild(errorNotice(message));
      this.tui.requestRender();
    } finally {
      this.inTurn = false;
      this.editor.disableSubmit = false;
      this.statusLoader.stop();
      this.tui.requestRender();
    }
  }

  /** Display-only skills browser: catalog metadata + discovery scope. */
  private async openSkillsPicker(): Promise<void> {
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice("/skills cannot run while another command is active"));
      return;
    }
    this.commandBusy = true;
    this.editor.disableSubmit = true;
    this.setCommandStatus("loading skills catalog");
    try {
      const outcome = parseSkillsOutcome(await this.requireApp().invokeCommand("skills", "{}"));
      if (outcome.type !== "success") {
        this.addTranscriptChild(
          errorNotice(`/skills: ${outcome.type === "failure" ? outcome.reason : outcome.prompt}`),
        );
        this.finishCommand();
        return;
      }
      this.skillsOverlay.open(outcome.entries, () => this.finishCommand());
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`/skills failed: ${errorMessage(error)}`));
      this.finishCommand();
    }
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
    this.commandBusy = true;
    this.editor.disableSubmit = true;
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
      this.finishCommand();
    };
    list.onSelect = (item) => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      const capability = capabilities.find((entry) => entry.id === item.value);
      if (capability === undefined) {
        this.finishCommand();
        this.addTranscriptChild(errorNotice(`/login: unknown authentication provider ${item.value}`));
        return;
      }
      void this.chooseLoginMethod(capability).catch((error: unknown) => {
        this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
        this.finishCommand();
      });
    };
    list.onCancel = close;
    handle = this.tui.showOverlay(panel, {
      width: "56%",
      maxHeight: "60%",
      anchor: "center",
      margin: 1,
    });
    this.providerPickerHandle = handle;
    this.tui.requestRender();
  }

  private showAuthMethodPicker(capability: ProviderAuthCapability): void {
    this.commandBusy = true;
    this.editor.disableSubmit = true;
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
      this.finishCommand();
    };
    list.onSelect = (item) => {
      handle?.hide();
      if (this.providerPickerHandle === handle) this.providerPickerHandle = undefined;
      void this.runLogin(capability.id, item.value).catch((error: unknown) => {
        this.addTranscriptChild(errorNotice(`/login failed: ${errorMessage(error)}`));
      });
    };
    list.onCancel = close;
    handle = this.tui.showOverlay(panel, {
      width: "62%",
      maxHeight: "60%",
      anchor: "center",
      margin: 1,
    });
    this.providerPickerHandle = handle;
    this.tui.requestRender();
  }

  private async runLogin(provider: string, method?: string): Promise<void> {
    // Provider picker already owns the command lock. Direct `/login p` takes
    // it here; the picker path leaves it set until this method finishes.
    this.commandBusy = true;
    this.editor.disableSubmit = true;
    if (method === "oauth") this.oauthOverlay.show(provider);
    this.setCommandStatus(`authenticating ${provider}`);
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
      this.finishCommand();
    }
  }

  private async invokeCommand(command: string, rawArgs: string): Promise<void> {
    if (command.length < 2 || !command.startsWith("/")) return;
    if (this.commandBusy) {
      this.addTranscriptChild(errorNotice(`${command} cannot run while another command is active`));
      return;
    }
    this.commandBusy = true;
    this.editor.disableSubmit = true;
    this.setCommandStatus(`running ${command}`);
    try {
      const outcome = parseCommandOutcome(
        await this.requireApp().invokeCommand(command.slice(1), parsePositionalArgs(rawArgs, command)),
      );
      this.renderOutcome(outcome, command);
    } catch (error: unknown) {
      this.addTranscriptChild(errorNotice(`${command} failed: ${errorMessage(error)}`));
    } finally {
      this.finishCommand();
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
  const asNumber = Number(trimmed);
  if (Number.isInteger(asNumber)) return JSON.stringify({ index: asNumber });
  return JSON.stringify({ _positional: trimmed });
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
