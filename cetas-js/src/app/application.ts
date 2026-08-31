import {
  CetasApplicationError,
  type AgentCallbacks,
  type AppSnapshot,
  type AppState,
  type CetasAgentBridge,
  type CetasHostConfig,
  type CancellationToken,
  type CommandDescriptor,
  type ImageAttachment,
  type ProviderSetupSnapshot,
} from "./types.ts";

/**
 * Commands invocable while a turn is running. Membership requires that the
 * command mutates only host-side policy state without touching the run loop,
 * session, or provider catalogs.
 */
const MID_TURN_COMMANDS = new Set(["permission"]);

export interface CetasApplicationOptions<AgentHandle = unknown> {
  bridge: CetasAgentBridge<AgentHandle>;
  config: CetasHostConfig;
  callbacks: AgentCallbacks;
  initialSessionId: string;
  onStateChange?: (snapshot: AppSnapshot) => void;
}

class ApplicationCancellation implements CancellationToken {
  private cancelled = false;

  isCancelled(): boolean {
    return this.cancelled;
  }

  reset(): void {
    this.cancelled = false;
  }

  cancel(): void {
    this.cancelled = true;
  }
}

/**
 * Application coordinator for cetas-js.
 *
 * It owns the process-lifetime Agent handle and nothing below the Posoco
 * product boundary.  In particular, it never creates a Puppet, catalog,
 * HostRuntime, journal, provider adapter, or OAuth implementation.
 */
export class CetasApplication<AgentHandle = unknown> {
  private state: AppState = "needs_setup";
  private setup: ProviderSetupSnapshot = {
    providers: [],
    oauthProviders: [],
  };
  private agent: AgentHandle | undefined;
  private currentSessionId: string;
  private lastError: string | undefined;
  /** Only an in-flight setup operation is cached; completed discovery is not. */
  private startPromise: Promise<AppSnapshot> | undefined;
  /** A startup catalog refresh is attempted at most once per app instance. */
  private startupRefreshAttempted = false;
  private activeTurn: Promise<string> | undefined;
  /** Abort controller for the in-flight turn; aborting interrupts the model fetch. */
  private activeAbort: AbortController | undefined;
  private activeCommand: Promise<string> | undefined;
  private readonly cancellation = new ApplicationCancellation();
  private shutdownPromise: Promise<void> | undefined;

  constructor(private readonly options: CetasApplicationOptions<AgentHandle>) {
    if (options.initialSessionId.length === 0) {
      throw new CetasApplicationError(
        "invalid_state",
        "initial session id must not be empty",
      );
    }
    this.currentSessionId = options.initialSessionId;
  }

  snapshot(): AppSnapshot {
    return {
      state: this.state,
      setup: this.setup,
      sessionId: this.currentSessionId,
      ...(this.lastError === undefined ? {} : { error: this.lastError }),
    };
  }

  get appState(): AppState {
    return this.state;
  }

  get sessionId(): string {
    return this.currentSessionId;
  }

  /**
   * Inspect provider-owned capabilities before composing an Agent.  An empty
   * catalog is a valid NeedsSetup state, not a composition attempt and not an
  * exception to hide.
  */
  start(): Promise<AppSnapshot> {
    if (this.state === "shutting_down") {
      return Promise.reject(
        new CetasApplicationError(
          "shutting_down",
          "cannot start cetas-js after shutdown has begun",
        ),
      );
    }
    if (this.startPromise !== undefined) return this.startPromise;
    if (this.activeTurn !== undefined || this.activeCommand !== undefined) {
      return Promise.reject(
        new CetasApplicationError(
          "already_running",
          "cannot rediscover setup while another application operation is running",
        ),
      );
    }
    // `start` is idempotent once an Agent is ready. Call `refreshSetup` when
    // the caller explicitly wants to re-read settings or provider state.
    if (this.state === "ready") return Promise.resolve(this.snapshot());
    // Catalog discovery is an explicit lifecycle operation. The bridge keeps
    // a private per-application repository; startup is the only implicit
    // all-provider refresh, and even a failed/empty attempt is not retried by
    // calling start() again.
    if (this.options.bridge.refreshModelCatalogs !== undefined) {
      if (this.startupRefreshAttempted) return Promise.resolve(this.snapshot());
      this.startupRefreshAttempted = true;
      return this.beginSetup(false, []);
    }
    return this.beginSetup(false);
  }

  /**
   * Explicitly re-read provider-owned setup and compose an Agent if needed.
   *
   * Discovery is deduplicated only while it is in flight. Once it completes,
   * a later refresh calls the bridge again instead of returning a permanently
   * memoized snapshot. This is the path used after settings edits or login.
   */
  refreshSetup(options: { refreshCatalogs?: boolean } = {}): Promise<AppSnapshot> {
    if (this.state === "shutting_down") {
      return Promise.reject(
        new CetasApplicationError(
          "shutting_down",
          "cannot refresh setup after shutdown has begun",
        ),
      );
    }
    if (this.activeTurn !== undefined || this.activeCommand !== undefined) {
      return Promise.reject(
        new CetasApplicationError(
          "already_running",
          "cannot refresh setup while another application operation is running",
        ),
      );
    }
    if (this.startPromise !== undefined) return this.startPromise;
    return this.beginSetup(
      true,
      options.refreshCatalogs && this.options.bridge.refreshModelCatalogs !== undefined
        ? []
        : undefined,
    );
  }

  private beginSetup(
    recomposeAgent: boolean,
    refreshProviders?: readonly string[],
  ): Promise<AppSnapshot> {
    // Defer initialization one microtask so startPromise is installed before
    // any bridge callback can re-enter start/refresh/shutdown.
    const promise = Promise.resolve().then(async () => {
      if (refreshProviders !== undefined) {
        // Invoke through the bridge object itself: extracting the method and
        // calling it unbound drops the receiver, so class-backed bridges
        // crash dereferencing their own fields (e.g. `this.runtimeValue`).
        const bridge = this.options.bridge;
        if (bridge.refreshModelCatalogs !== undefined) {
          try {
            await bridge.refreshModelCatalogs(
              this.options.config,
              refreshProviders.length === 0 ? undefined : refreshProviders,
            );
          } catch (error: unknown) {
            this.lastError = errorMessage(error);
            this.publish();
            throw new CetasApplicationError(
              "bridge_failure",
              `cetas-js model catalog refresh failed: ${errorMessage(error)}`,
              error,
            );
          }
        }
      }
      return this.initialize(recomposeAgent);
    });
    this.startPromise = promise;
    // Clear only the in-flight promise. A successful snapshot must not make
    // future explicit refreshes stale, while concurrent callers still share
    // one bridge discovery operation.
    void promise.then(
      () => {
        if (this.startPromise === promise) this.startPromise = undefined;
      },
      () => {
        if (this.startPromise === promise) this.startPromise = undefined;
      },
    );
    return promise;
  }

  private async initialize(recomposeAgent: boolean): Promise<AppSnapshot> {
    try {
      if (this.state === "shutting_down") return this.snapshot();
      const setup = await this.options.bridge.describeSetup(this.options.config);
      this.setup = setup;
      this.lastError = undefined;
      if (setup.providers.length === 0) {
        // A refresh can invalidate a previously composed Agent. Release it
        // before exposing NeedsSetup so no stale provider state remains live.
        if (this.agent !== undefined && (this.state as AppState) !== "shutting_down") {
          const previousAgent = this.agent;
          this.agent = undefined;
          await this.options.bridge.shutdown(previousAgent);
        }
        if ((this.state as AppState) !== "shutting_down") this.transition("needs_setup");
        return this.snapshot();
      }
      // Shutdown may have begun while discovery was awaiting the bridge. Do
      // not create a new Agent after the terminal state has been requested;
      // shutdown() will clean up any Agent already in flight.
      if (
        recomposeAgent &&
        this.agent !== undefined &&
        (this.state as AppState) !== "shutting_down"
      ) {
        const previousAgent = this.agent;
        this.agent = undefined;
        await this.options.bridge.shutdown(previousAgent);
      }
      if ((this.state as AppState) !== "shutting_down" && this.agent === undefined) {
        this.agent = await this.options.bridge.createAgent(
          this.options.config,
          this.options.callbacks,
          this.cancellation,
        );
      }
      if ((this.state as AppState) !== "shutting_down") this.transition("ready");
      return this.snapshot();
    } catch (error: unknown) {
      const primaryError = error;
      this.lastError = errorMessage(error);
      // Setup discovery failures are not silently turned into an empty
      // catalog.  The application remains visible, but the failure is exposed
      // for the UI/logging layer to report.
      let cleanupError: unknown;
      if (
        this.agent !== undefined &&
        (this.state as AppState) !== "shutting_down"
      ) {
        const staleAgent = this.agent;
        this.agent = undefined;
        try {
          await this.options.bridge.shutdown(staleAgent);
        } catch (error: unknown) {
          cleanupError = error;
        }
      }
      if ((this.state as AppState) !== "shutting_down") this.transition("needs_setup");
      if (cleanupError !== undefined) {
        throw new CetasApplicationError(
          "bridge_failure",
          `cetas-js setup failed: ${this.lastError}; stale Agent cleanup failed: ${errorMessage(cleanupError)}`,
          cleanupError,
        );
      }
      throw new CetasApplicationError(
        "bridge_failure",
        `cetas-js setup failed: ${this.lastError}`,
        primaryError,
      );
    }
  }

  setSession(sessionId: string): void {
    if (sessionId.length === 0) {
      throw new CetasApplicationError(
        "invalid_state",
        "session id must not be empty",
      );
    }
    if (
      this.state === "running" ||
      this.activeTurn !== undefined ||
      this.activeCommand !== undefined ||
      this.startPromise !== undefined
    ) {
      throw new CetasApplicationError(
        "already_running",
        "cannot change session while another application operation is running",
      );
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot change session after shutdown has begun",
      );
    }
    this.currentSessionId = sessionId;
    this.publish();
  }

  /**
   * Whether the active model accepts image input (`image_in` capability).
   * Absent bridge support (older bundles) reads as `true` so the gate never
   * blocks on a stale build; the encoder still downgrades safely.
   */
  supportsImageInput(): boolean {
    if (this.agent === undefined) return false;
    if (this.options.bridge.activeModelSupportsImages === undefined) return true;
    return this.options.bridge.activeModelSupportsImages(this.agent);
  }

  /** Execute one turn through the single long-lived Agent handle. */
  async runTurn(
    prompt: string,
    sessionId = this.currentSessionId,
    images?: readonly ImageAttachment[],
  ): Promise<string> {
    if (prompt.length === 0) {
      throw new CetasApplicationError("invalid_state", "prompt must not be empty");
    }
    if (sessionId.length === 0) {
      throw new CetasApplicationError("invalid_state", "session id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot run a turn after shutdown has begun",
      );
    }
    if (this.startPromise !== undefined || this.activeCommand !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        this.startPromise !== undefined
          ? "cannot run a turn while setup discovery is in progress"
          : "cannot run a turn while a command is running",
      );
    }
    if (this.state === "needs_setup" || this.agent === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "no model provider is configured; use /model or /login [provider] [method] to complete setup",
      );
    }
    if (this.state === "running") {
      throw new CetasApplicationError(
        "already_running",
        "a turn is already running",
      );
    }
    this.currentSessionId = sessionId;
    this.transition("running");
    const agent = this.agent;
    const abort = new AbortController();
    this.activeAbort = abort;
    const turnPromise = (async () => {
      try {
        // Install activeTurn before invoking the bridge, including for a
        // synchronous/re-entrant bridge implementation.
        await Promise.resolve();
        return await this.options.bridge.runTurn(
          agent,
          prompt,
          sessionId,
          abort.signal,
          images,
        );
      } catch (error: unknown) {
        this.lastError = errorMessage(error);
        this.publish();
        throw error;
      } finally {
        // Shutdown may have moved the application to its terminal state while
        // the bridge turn was still unwinding; only a still-running turn may
        // transition back to ready.
        this.activeTurn = undefined;
        if (this.activeAbort === abort) this.activeAbort = undefined;
        if ((this.state as AppState) === "running") this.transition("ready");
      }
    })();
    this.activeTurn = turnPromise;
    try {
      return await turnPromise;
    } finally {
      if (this.activeTurn === turnPromise) this.activeTurn = undefined;
    }
  }

  /**
   * Queue a user message on the active run instead of starting a new turn.
   * The Agent drains follow-ups one at a time at turn boundaries, driving a
   * full new turn per message. `"stale"` means the run ended between the
   * caller's check and this call — the caller should fall back to `runTurn`.
   */
  queueFollowUp(
    prompt: string,
    images?: readonly ImageAttachment[],
  ): "accepted" | "stale" | "full" {
    if (prompt.length === 0) {
      throw new CetasApplicationError("invalid_state", "prompt must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError("shutting_down", "cannot queue a message after shutdown has begun");
    }
    if (this.activeTurn === undefined || this.agent === undefined) {
      throw new CetasApplicationError("invalid_state", "no turn is active; use runTurn");
    }
    if (this.options.bridge.enqueueFollowUp === undefined) {
      throw new CetasApplicationError("bridge_failure", "bridge does not support follow-up queuing");
    }
    const raw = this.options.bridge.enqueueFollowUp(this.agent, prompt, images);
    if (raw.startsWith("Accepted")) return "accepted";
    if (raw.startsWith("RejectedStale")) return "stale";
    if (raw.startsWith("RejectedQueueFull")) return "full";
    throw new CetasApplicationError("bridge_failure", `unexpected follow-up outcome: ${raw}`);
  }

  /**
   * Return the extension command catalog.  Setup commands are available even
   * before an Agent exists; provider commands are supplied by the bridge once
  * the router is composed.
  */
  listCommands(): readonly CommandDescriptor[] {
    if (this.agent === undefined) {
      return [
        {
          id: "model",
          label: "Model",
          description: "List or select a configured model",
          category: "model",
          ctype: "select",
          params: [],
          aliases: [],
          visible: true,
        },
        {
          id: "login",
          label: "Login",
          description: "Authenticate with a provider",
          category: "auth",
          ctype: "action",
          params: [],
          aliases: [],
          visible: true,
        },
      ];
    }
    return this.options.bridge.listCommands(this.agent);
  }

  /**
   * One-shot workspace file index for `@`-mention autocomplete. Read-only and
   * Agent-free, so — unlike commands — it stays available during setup
   * discovery and mid-turn; only shutdown gates it. An empty result means the
   * bridge offers no workspace index (caller degrades to no completion).
   */
  async listWorkspaceFiles(): Promise<readonly string[]> {
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot list workspace files after shutdown has begun",
      );
    }
    if (this.options.bridge.listWorkspaceFiles === undefined) return [];
    const raw = await this.options.bridge.listWorkspaceFiles(this.options.config);
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      throw new CetasApplicationError(
        "bridge_failure",
        "workspace file index must be a JSON array",
      );
    }
    return parsed.filter((entry): entry is string => typeof entry === "string");
  }

  /** Invoke a provider/router command through the extension command port. */
  async invokeCommand(id: string, argsJson = "{}"): Promise<string> {
    if (id.length === 0) {
      throw new CetasApplicationError("invalid_state", "command id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot invoke a command after shutdown has begun",
      );
    }
    if (this.state === "running" || this.activeTurn !== undefined) {
      // Allowlisted commands only touch host-side policy state (e.g.
      // PermissionPolicy's mutable mode, re-read before every tool call), so
      // they are safe to invoke mid-turn. Everything else still waits.
      if (!MID_TURN_COMMANDS.has(id)) {
        throw new CetasApplicationError(
          "already_running",
          "cannot invoke a command while a turn is running",
        );
      }
    }
    if (this.startPromise !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        "cannot invoke a command while setup discovery is in progress",
      );
    }
    if (this.activeCommand !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        "another command is already running",
      );
    }
    this.cancellation.reset();
    // Defer the bridge call by one microtask so the lock is installed before
    // a synchronous/re-entrant bridge implementation can invoke the app.
    const commandPromise = Promise.resolve().then(() =>
      this.invokeCommandInternal(id, argsJson),
    );
    this.activeCommand = commandPromise;
    try {
      return await commandPromise;
    } finally {
      if (this.activeCommand === commandPromise) this.activeCommand = undefined;
      this.cancellation.reset();
    }
  }

  /** Request cooperative cancellation of the active provider command. */
  cancelCurrentOperation(): boolean {
    if (this.activeCommand === undefined) return false;
    this.cancellation.cancel();
    return true;
  }

  /**
   * Request an abort of the active turn (ESC interrupt). The mailbox abort
   * gives the loop its clean Cancelled path; the AbortController additionally
   * cancels the turn coroutine so an in-flight model request stops streaming
   * immediately. The turn promise settles with the partial transcript or, if
   * cancellation lands past the final safe point, rejects with an AbortError.
   * Returns false when no turn is active or the bridge has no abort seam.
   */
  interruptActiveTurn(): boolean {
    if (this.activeTurn === undefined || this.agent === undefined) return false;
    if (this.options.bridge.abortTurn === undefined && this.activeAbort === undefined) {
      return false;
    }
    this.options.bridge.abortTurn?.(this.agent);
    this.activeAbort?.abort();
    return true;
  }

  private async invokeCommandInternal(id: string, argsJson: string): Promise<string> {
    if (id === "login" && this.options.bridge.login !== undefined) {
      const login = loginArguments(argsJson);
      const hadAgent = this.agent !== undefined;
      const outcome = await this.options.bridge.login(
        this.options.config,
        login.provider,
        this.options.callbacks,
        this.cancellation,
        login.method,
      );
      // Cetas authenticates through the provider-neutral factory seam even
      // when an Agent already exists. This keeps `/login <provider>` capable
      // of reaching an unconfigured provider instead of depending on the
      // Router's ready-slot subset. A successful credential change requires a
      // fresh Agent so the new provider snapshot is actually installed.
      this.activeCommand = undefined;
      if (this.cancellation.isCancelled() || !commandOutcomeSucceeded(outcome)) {
        return outcome;
      }
      await this.beginSetup(
        hadAgent,
        this.options.bridge.refreshModelCatalogs === undefined
          ? undefined
          : [login.provider],
      );
      return outcome;
    }
    if (this.agent === undefined) {
      // Preserve a machine-readable result shape for the renderer while
      // making the setup requirement explicit.  This is not a fake success.
      return JSON.stringify({
        type: "failure",
        reason: "no Agent is composed; configure a provider first",
        code: "not_ready",
      });
    }
    const outcome = await this.options.bridge.invokeCommand(this.agent, id, argsJson);
    if (commandRequestsSetupRefresh(outcome)) {
      // Setup discovery is the serialization barrier while a profile load
      // rebuilds provider state. Avoid a re-entrant shutdown waiting on this
      // command promise during the ready-state publication.
      this.activeCommand = undefined;
      await this.beginSetup(true);
    }
    return outcome;
  }

  /**
   * Shutdown is idempotent and terminal.  The bridge owns Posoco lifecycle
   * cleanup and propagates any failure to the caller.
   */
  shutdown(): Promise<void> {
    if (this.shutdownPromise !== undefined) return this.shutdownPromise;
    const pendingSetup = this.startPromise;
    const pendingTurn = this.activeTurn;
    const pendingCommand = this.activeCommand;
    // Provider OAuth polling is owned by the bridge, but its cancellation
    // token is shared with the application lifetime.  Direct/headless
    // shutdown must request cancellation before waiting for the command;
    // otherwise only TerminalShell's overlay close path can unblock polling.
    if (pendingCommand !== undefined) this.cancellation.cancel();
    this.transition("shutting_down");
    this.shutdownPromise = (async () => {
      let pendingError: unknown;
      for (const pending of [pendingSetup, pendingTurn, pendingCommand]) {
        if (pending === undefined) continue;
        try {
          await pending;
        } catch (error: unknown) {
          // The operation's caller already observes this failure. Still wait
          // for it before Agent cleanup, then rethrow it unless cleanup fails.
          if (pendingError === undefined) pendingError = error;
        }
      }
      if (this.agent !== undefined) {
        const agent = this.agent;
        this.agent = undefined;
        await this.options.bridge.shutdown(agent);
      }
      if (pendingError !== undefined) throw pendingError;
    })();
    return this.shutdownPromise;
  }

  private transition(next: AppState): void {
    const previous = this.state;
    if (previous === next) {
      this.publish();
      return;
    }
    const allowed =
      (previous === "needs_setup" && (next === "ready" || next === "shutting_down")) ||
      (previous === "ready" && (next === "running" || next === "needs_setup" || next === "shutting_down")) ||
      (previous === "running" && (next === "ready" || next === "shutting_down")) ||
      (previous === "shutting_down" && next === "shutting_down");
    if (!allowed) {
      throw new CetasApplicationError(
        "invalid_state",
        `invalid cetas-js state transition: ${previous} → ${next}`,
      );
    }
    this.state = next;
    this.publish();
  }

  private publish(): void {
    this.options.onStateChange?.(this.snapshot());
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function loginArguments(argsJson: string): { provider: string; method?: string } {
  let raw: unknown;
  try {
    raw = JSON.parse(argsJson);
  } catch (error: unknown) {
    throw new CetasApplicationError(
      "invalid_state",
      `/login arguments must be valid JSON: ${errorMessage(error)}`,
      error,
    );
  }
  if (typeof raw === "string") {
    if (raw.length === 0) throw new CetasApplicationError("invalid_state", "/login requires a provider string");
    return { provider: raw };
  }
  if (typeof raw === "object" && raw !== null && !Array.isArray(raw)) {
    const value = raw as Record<string, unknown>;
    const provider = value.provider;
    if (typeof provider === "string" && provider.length > 0) {
      const method = value.method;
      if (method === undefined) return { provider };
      if (typeof method !== "string" || method.length === 0) {
        throw new CetasApplicationError("invalid_state", "/login method must be a non-empty string");
      }
      return { provider, method };
    }
  }
  throw new CetasApplicationError(
    "invalid_state",
    "/login requires a provider string",
  );
}

/**
 * Provider login is a command boundary, but its success must be known before
 * replacing a live Agent. Cetas bridges return the normal CommandOutcome JSON
 * shape; malformed output is a bridge failure rather than an implicit success.
 */
function commandOutcomeSucceeded(raw: string): boolean {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (error: unknown) {
    throw new CetasApplicationError(
      "bridge_failure",
      `login outcome must be valid JSON: ${errorMessage(error)}`,
      error,
    );
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new CetasApplicationError("bridge_failure", "login outcome must be an object");
  }
  const type = (value as Record<string, unknown>).type;
  if (type === "success") return true;
  if (type === "failure" || type === "needs_input") return false;
  throw new CetasApplicationError("bridge_failure", "login outcome.type is unsupported");
}

function commandRequestsSetupRefresh(raw: string): boolean {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (error: unknown) {
    throw new CetasApplicationError(
      "bridge_failure",
      `command outcome must be valid JSON: ${errorMessage(error)}`,
      error,
    );
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new CetasApplicationError("bridge_failure", "command outcome must be an object");
  }
  const hint = (value as Record<string, unknown>).ui_hint;
  if (hint === undefined) return false;
  if (typeof hint !== "string") {
    throw new CetasApplicationError("bridge_failure", "command outcome.ui_hint must be a string");
  }
  // `/model` returns the already-composed router catalog. It must never cause
  // an implicit setup rediscovery or provider network call; only profile/settings
  // changes request the explicit recompose path.
  return hint === "refresh_settings";
}

export type {
  AppSnapshot,
  AgentCallbacks,
  CetasAgentBridge,
  CetasHostConfig,
  CancellationToken,
} from "./types.ts";
