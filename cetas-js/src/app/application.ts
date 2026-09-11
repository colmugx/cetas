import {
  CetasApplicationError,
  type AgentCallbacks,
  type AppSnapshot,
  type AppState,
  type CetasAgentBridge,
  type CetasHostConfig,
  type CatalogRefreshSummary,
  type CancellationToken,
  type CommandDescriptor,
  type ImageAttachment,
  type ProviderSetupSnapshot,
  type SessionTitle,
} from "./types.ts";
import type { PiPackagesSummary } from "./pi-packages.ts";
import type { CompactSessionOutcome } from "./moonbit-bridge.ts";

/**
 * Commands invocable while a turn is running. Membership requires that the
 * command mutates only host-side policy state without touching the run loop,
 * session, or provider catalogs. `/compact` is not a member: it is a
 * first-class operation with its own mid-turn switch semantics (compactSession).
 */
const MID_TURN_COMMANDS = new Set(["permission", "status"]);

/**
 * Bridges exposing the Agent-level server compaction entry. An intersection
 * so older bridges without `compactSession` still compose.
 */
type CompactCapableBridge<AgentHandle> = CetasAgentBridge<AgentHandle> & {
  compactSession?(
    agent: AgentHandle,
    sessionId: string,
    signal?: AbortSignal,
  ): Promise<CompactSessionOutcome>;
};

export interface CetasApplicationOptions<AgentHandle = unknown> {
  bridge: CetasAgentBridge<AgentHandle>;
  config: CetasHostConfig;
  callbacks: AgentCallbacks;
  initialSessionId: string;
  onStateChange?: (snapshot: AppSnapshot) => void;
  /**
   * Summary of the once-per-instance background live catalog refresh
   * (per-provider refreshed/failed entries). Hosts that attach the
   * application after the renderer can register later via
   * setOnCatalogRefresh instead.
   */
  onCatalogRefresh?: (summary: CatalogRefreshSummary) => void;
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

interface RateLimitMonitor<AgentHandle> {
  agent: AgentHandle;
  controller: AbortController;
  settled: Promise<void>;
  generation: number;
}

/** The once-per-instance background live catalog refresh task. */
interface LiveCatalogRefreshTask {
  controller: AbortController;
  settled: Promise<void>;
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
  /** Live catalog-refresh summaries (options-registered or attached later). */
  private onCatalogRefresh: ((summary: CatalogRefreshSummary) => void) | undefined;
  /** The background live refresh launches at most once per app instance. */
  private liveRefreshStarted = false;
  private liveCatalogRefresh: LiveCatalogRefreshTask | undefined;
  private activeTurn: Promise<string> | undefined;
  /** Abort controller for the in-flight turn; aborting interrupts the model fetch. */
  private activeAbort: AbortController | undefined;
  private activeCommand: Promise<string> | undefined;
  /** Set while a /compact switch waits for the interrupted operation's finalize. */
  private waitingForCleanup = false;
  /** Set while a compact operation owns the busy state. */
  private compactInFlight = false;
  /** Abort controller for the in-flight compact; Esc reaches it like a turn. */
  private compactAbort: AbortController | undefined;
  /**
   * Mirror of follow-ups accepted but not yet drained by the Agent (the
   * core keeps them queued across operations and starts them at a later
   * run's boundary). Hosts render these as pending user input.
   */
  private pendingFollowUps: Array<{
    prompt: string;
    images?: readonly ImageAttachment[];
  }> = [];
  private rateLimitMonitor: RateLimitMonitor<AgentHandle> | undefined;
  /** A monitor teardown remains a serialization barrier until its promise settles. */
  private rateLimitMonitorSettling: Promise<void> | undefined;
  /** Host generation for pending recovery; context changes invalidate older callbacks. */
  private rateLimitContextGeneration = 0;
  /** Deferred restart requested while a command/turn owns the Agent. */
  private rateLimitMonitorRestartRequest:
    { agent: AgentHandle; generation: number } | undefined;
  /** Only a live monitor may turn an otherwise idle observer event into recovery. */
  private rateLimitRecoveryEligible = false;
  private recoveryTurnActive = false;
  /**
   * Follow-ups accepted while a recovery run owns the busy state. Each drains
   * as another turn after TurnCompleted, so the busy state must persist until
   * the last queued follow-up's turn completes.
   */
  private recoveryFollowUpsQueued = 0;
  private readonly cancellation = new ApplicationCancellation();
  private shutdownPromise: Promise<void> | undefined;
  private piPackages: PiPackagesSummary | undefined;

  constructor(private readonly options: CetasApplicationOptions<AgentHandle>) {
    if (options.initialSessionId.length === 0) {
      throw new CetasApplicationError(
        "invalid_state",
        "initial session id must not be empty",
      );
    }
    this.currentSessionId = options.initialSessionId;
    this.onCatalogRefresh = options.onCatalogRefresh;
  }

  /**
   * Register the live catalog-refresh summary handler. Hosts whose renderer
   * is constructed before the application (terminal composition order) attach
   * it here instead of the options object; a later registration replaces the
   * options-provided handler.
   */
  setOnCatalogRefresh(handler: (summary: CatalogRefreshSummary) => void): void {
    this.onCatalogRefresh = handler;
  }

  snapshot(): AppSnapshot {
    return {
      state: this.state,
      setup: this.setup,
      sessionId: this.currentSessionId,
      ...(this.lastError === undefined ? {} : { error: this.lastError }),
      ...(this.piPackages === undefined ? {} : { piPackages: this.piPackages }),
    };
  }

  get appState(): AppState {
    return this.state;
  }

  get sessionId(): string {
    return this.currentSessionId;
  }

  get rateLimitRecoveryActive(): boolean {
    return this.recoveryTurnActive;
  }

  /**
   * Prompts accepted on a run that ended before draining them. They were
   * dropped from the Agent's queue by its finalize; the app keeps them
   * visible and pending until the user explicitly resubmits.
   */
  get pendingInputs(): readonly string[] {
    return this.pendingFollowUps.map((entry) => entry.prompt);
  }

  get compactPending(): boolean {
    return this.compactInFlight || this.waitingForCleanup;
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
    // Compose-first startup: discovery reads only what the local catalogs
    // already hold (process cache, disk-cache seed) with no network await.
    // The once-per-instance refresh of the configured providers runs as a
    // cancellable background task once this settles; the MoonBit live-refresh
    // entry persists the caches and hot-swaps the composed agent's router
    // before its summary reaches the host. A failed composition does not
    // suppress the launch — a fresh catalog can repair a needs_setup boot;
    // a snapshot with zero configured providers has nothing to refresh and
    // skips the task.
    const promise = this.beginSetup(false);
    void promise.then(
      () => this.startLiveCatalogRefresh(),
      () => this.startLiveCatalogRefresh(),
    );
    return promise;
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
          this.rateLimitContextGeneration += 1;
          await this.stopRateLimitMonitor(true);
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
        this.rateLimitContextGeneration += 1;
        await this.stopRateLimitMonitor(true);
        await this.options.bridge.shutdown(previousAgent);
      }
      if ((this.state as AppState) !== "shutting_down" && this.agent === undefined) {
        this.agent = await this.options.bridge.createAgent(
          this.options.config,
          this.agentCallbacks(),
          this.cancellation,
        );
        this.piPackages = this.options.bridge.piPackages;
      }
      if ((this.state as AppState) !== "shutting_down") {
        this.transition("ready");
        if (this.agent !== undefined) {
          this.startRateLimitMonitor(this.agent, this.rateLimitContextGeneration);
        }
      }
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
          this.rateLimitContextGeneration += 1;
          await this.stopRateLimitMonitor(true);
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

  /**
   * Launch the once-per-instance background live catalog refresh (the
   * rate-limit monitor idiom: an AbortController marks cancellation, the
   * settled promise is a shutdown serialization barrier). Startup composed
   * from local caches only; this task asks the configured providers for
   * fresh `/models` lists, and the MoonBit entry has already persisted
   * caches and hot-swapped the composed agent's router by the time the
   * summary arrives.
   */
  private startLiveCatalogRefresh(): void {
    if (this.liveRefreshStarted) return;
    if ((this.state as AppState) === "shutting_down") return;
    const bridge = this.options.bridge;
    if (bridge.refreshModelListsLive === undefined) return;
    // Refresh only the providers the settled setup snapshot reports as
    // configured (its provider list is the logged-in subset); iterating
    // unconfigured providers would surface "not configured" failures for
    // providers the user never logged into. Zero configured providers means
    // nothing to refresh: do not launch.
    const configuredProviders = Array.from(
      new Set(this.setup.providers.map((capability) => capability.provider)),
    );
    if (configuredProviders.length === 0) return;
    this.liveRefreshStarted = true;
    const controller = new AbortController();
    const settled = Promise.resolve()
      .then(() =>
        bridge.refreshModelListsLive!(
          this.options.config,
          JSON.stringify(configuredProviders),
        ),
      )
      .then(
        (raw: string) => {
          if (!controller.signal.aborted) this.handleLiveCatalogRefreshSummary(raw);
        },
        (error: unknown) => {
          // The MoonBit entry resolves failures into its summary; a rejection
          // can only be a bridge defect. Surface it without crashing the app.
          if (controller.signal.aborted) return;
          this.lastError = `live model catalog refresh failed: ${errorMessage(error)}`;
          this.publish();
        },
      );
    this.liveCatalogRefresh = { controller, settled };
  }

  /** Abort the live refresh and wait for it to settle (shutdown barrier). */
  private stopLiveCatalogRefresh(): Promise<void> {
    const task = this.liveCatalogRefresh;
    if (task === undefined) return Promise.resolve();
    this.liveCatalogRefresh = undefined;
    task.controller.abort();
    return task.settled;
  }

  private handleLiveCatalogRefreshSummary(raw: string): void {
    let summary: CatalogRefreshSummary;
    try {
      summary = parseCatalogRefreshSummary(raw);
    } catch (error: unknown) {
      this.lastError = `live model catalog refresh returned an invalid summary: ${errorMessage(error)}`;
      this.publish();
      return;
    }
    // A fresh catalog can repair a first-boot needs_setup (no local cache).
    // Recompose only when idle — the same busy guards an explicit
    // refreshSetup enforces; its rejection path already surfaced the error.
    if (
      this.state === "needs_setup" &&
      summary.results.some((entry) => entry.status === "refreshed") &&
      this.activeTurn === undefined &&
      this.activeCommand === undefined &&
      this.startPromise === undefined
    ) {
      void this.refreshSetup().catch(() => undefined);
    }
    try {
      this.onCatalogRefresh?.(summary);
    } catch (callbackError: unknown) {
      console.error("catalog refresh handler failed", callbackError);
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
    this.invalidateRateLimitContext();
    this.currentSessionId = sessionId;
    this.publish();
  }

  /**
   * Record an observed session_redirect as an application fact.
   *
   * A redirect arrives mid-turn after the runtime already moved the live
   * thread (e.g. compact-NewThread), so hosts adopt it the moment they see
   * it — deliberately without setSession's running/activeTurn/startPromise
   * guards, which exist for user-intent switches only. setSession remains
   * the user-intent path and keeps those guards.
   */
  adoptSessionRedirect(to: string): void {
    if (to.length === 0) {
      throw new CetasApplicationError(
        "invalid_state",
        "redirect target session id must not be empty",
      );
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot adopt a session redirect after shutdown has begun",
      );
    }
    this.currentSessionId = to;
    this.publish();
  }

  /**
   * Rewind the persisted session transcript: drop stored messages at
   * `fromIndex` and after, keeping `[0, fromIndex)`. The next turn on the
   * session reloads from the truncated point. Idle-only: a rewind racing the
   * run loop's own session writes would corrupt the transcript, so the same
   * busy guards as setSession apply.
   */
  async rewind(sessionId: string, fromIndex: number): Promise<void> {
    if (sessionId.length === 0) {
      throw new CetasApplicationError("invalid_state", "session id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot rewind after shutdown has begun",
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
        "cannot rewind while another application operation is running",
      );
    }
    if (this.agent === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "no Agent is composed; configure a provider first",
      );
    }
    await this.options.bridge.rewind(this.agent, sessionId, fromIndex);
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
    const turnGeneration = ++this.rateLimitContextGeneration;
    this.rateLimitRecoveryEligible = false;
    const abort = new AbortController();
    this.activeAbort = abort;
    const turnPromise = (async () => {
      try {
        // Install activeTurn before invoking the bridge, including for a
        // synchronous/re-entrant bridge implementation.
        await Promise.resolve();
        // A fresh user intent supersedes the interrupted request. Cancelling
        // before entering the Agent also serializes this turn with a recovery
        // that became due in the preceding microtask.
        await this.stopRateLimitMonitor(true);
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
      if ((this.state as AppState) !== "shutting_down" && this.agent === agent) {
        this.startRateLimitMonitor(agent, turnGeneration);
      }
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
    if (
      (this.activeTurn === undefined && !this.recoveryTurnActive) ||
      this.agent === undefined
    ) {
      throw new CetasApplicationError("invalid_state", "no turn is active; use runTurn");
    }
    if (this.options.bridge.enqueueFollowUp === undefined) {
      throw new CetasApplicationError("bridge_failure", "bridge does not support follow-up queuing");
    }
    const raw = this.options.bridge.enqueueFollowUp(this.agent, prompt, images);
    if (raw.startsWith("Accepted")) {
      // A user run drains its own follow-ups inside the runTurn promise; a
      // recovery run is host-tracked, so its queued follow-ups extend it.
      if (this.recoveryTurnActive) this.recoveryFollowUpsQueued += 1;
      this.pendingFollowUps.push({ prompt, images });
      return "accepted";
    }
    if (raw.startsWith("RejectedStale")) return "stale";
    if (raw.startsWith("RejectedQueueFull")) return "full";
    throw new CetasApplicationError("bridge_failure", `unexpected follow-up outcome: ${raw}`);
  }

  /**
   * Run the Agent-level server compaction for one session.
   *
   * Idle: a direct compact on the long-lived Agent. While a turn or recovery
   * run is active: interrupt it, wait for its single finalize, then compact —
   * the interrupted task is not resumed and its undrained follow-ups stay
   * pending (pendingInputs). Concurrent operations are rejected with a
   * waiting-for-cleanup error instead of writing the session concurrently.
   * The compact carries its own AbortController (Esc reaches it); a cancelled
   * compact reports `cancelled` and can be rerun.
   */
  async compactSession(
    sessionId: string = this.currentSessionId,
  ): Promise<CompactSessionOutcome> {
    if (sessionId.length === 0) {
      throw new CetasApplicationError("invalid_state", "session id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot compact after shutdown has begun",
      );
    }
    if (this.state === "needs_setup" || this.agent === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "no Agent is composed; configure a provider first",
      );
    }
    if (this.startPromise !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        "cannot compact while setup discovery is in progress",
      );
    }
    if (this.compactInFlight || this.activeCommand !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        this.waitingForCleanup
          ? "waiting for the interrupted operation to finish cleanup; retry the compact once it settles"
          : "another command is already running",
      );
    }
    const bridge = this.options.bridge as CompactCapableBridge<AgentHandle>;
    if (bridge.compactSession === undefined) {
      throw new CetasApplicationError(
        "bridge_failure",
        "bridge does not support session compaction",
      );
    }
    const agent = this.agent;
    const switchRequested = this.activeTurn !== undefined || this.recoveryTurnActive;
    this.currentSessionId = sessionId;
    const compactPromise = Promise.resolve().then(() =>
      this.runCompactLocked(bridge, agent, sessionId, switchRequested),
    );
    // The command lock is typed Promise<string>; the compact rides it only to
    // serialize against other commands and shutdown.
    const lock = compactPromise as unknown as Promise<string>;
    this.compactInFlight = true;
    this.activeCommand = lock;
    try {
      return await compactPromise;
    } finally {
      if (this.activeCommand === lock) {
        this.activeCommand = undefined;
      }
      this.compactInFlight = false;
      this.waitingForCleanup = false;
      this.flushRateLimitMonitorRestart();
    }
  }

  /** Compact body; the caller owns the activeCommand lock. */
  private async runCompactLocked(
    bridge: CompactCapableBridge<AgentHandle>,
    agent: AgentHandle,
    sessionId: string,
    switchRequested: boolean,
  ): Promise<CompactSessionOutcome> {
    if ((this.state as AppState) !== "shutting_down") this.transition("running");
    const turnGeneration = this.rateLimitContextGeneration;
    if (switchRequested) {
      this.waitingForCleanup = true;
      this.publish();
      this.interruptActiveTurn();
      await this.waitForActiveOperationFinalize();
      if (this.agent !== agent || (this.state as AppState) === "shutting_down") {
        if ((this.state as AppState) === "running") this.transition("ready");
        return {
          ok: false,
          errorKind: "error",
          detail: "compact abandoned: the agent was replaced during cleanup",
        };
      }
    }
    const abort = new AbortController();
    this.compactAbort = abort;
    try {
      await this.stopRateLimitMonitor(true);
      return await bridge.compactSession!(agent, sessionId, abort.signal);
    } finally {
      if (this.compactAbort === abort) this.compactAbort = undefined;
      if ((this.state as AppState) === "running") this.transition("ready");
      if ((this.state as AppState) !== "shutting_down" && this.agent === agent) {
        this.startRateLimitMonitor(agent, turnGeneration);
      }
    }
  }

  /**
   * Wait until the interrupted operation's single finalize has released the
   * busy state. The turn path settles its own promise; a monitor-driven
   * recovery run is host-tracked, so poll its flag.
   */
  private async waitForActiveOperationFinalize(): Promise<void> {
    const deadline = Date.now() + 5000;
    while (this.activeTurn !== undefined || this.recoveryTurnActive) {
      if (Date.now() >= deadline) {
        throw new CetasApplicationError(
          "already_running",
          "timed out waiting for the interrupted operation to finish cleanup",
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
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

  /**
   * One-shot session titles for the /sessions picker (MoonBit `display_title`:
   * metadata name ?? first user message prefix ?? id). Stateless and
   * Agent-free like the workspace index; unavailable bridges degrade to an
   * empty list so the picker keeps its id-based labels.
   */
  async sessionTitles(sessionsDir: string): Promise<readonly SessionTitle[]> {
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot list session titles after shutdown has begun",
      );
    }
    if (this.options.bridge.sessionTitles === undefined) return [];
    const raw = await this.options.bridge.sessionTitles(sessionsDir);
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      throw new CetasApplicationError(
        "bridge_failure",
        "session titles response must be a JSON array",
      );
    }
    return parsed.map((entry, index) => {
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        throw new CetasApplicationError(
          "bridge_failure",
          `session titles entry ${index} must be an object`,
        );
      }
      const record = entry as Record<string, unknown>;
      if (typeof record.id !== "string" || typeof record.title !== "string") {
        throw new CetasApplicationError(
          "bridge_failure",
          `session titles entry ${index} must carry string id and title`,
        );
      }
      return { id: record.id, title: record.title };
    });
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
      // they are safe to invoke mid-turn. `/compact` is likewise admitted:
      // it owns mid-turn switch semantics (interrupt → finalize → compact).
      // Everything else still waits.
      if (!MID_TURN_COMMANDS.has(id) && id !== "compact") {
        throw new CetasApplicationError(
          "already_running",
          this.waitingForCleanup
            ? "waiting for the interrupted operation to finish cleanup"
            : "cannot invoke a command while a turn is running",
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
        this.waitingForCleanup
          ? "waiting for the interrupted operation to finish cleanup before starting the compact"
          : "another command is already running",
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
      this.flushRateLimitMonitorRestart();
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
    if (this.compactAbort !== undefined) {
      // Esc during a compact cancels the compact operation itself; the
      // mailbox abort gives the compact run its typed cancelled finalize.
      if (this.agent !== undefined) this.options.bridge.abortTurn?.(this.agent);
      this.compactAbort.abort();
      return true;
    }
    if (
      (this.activeTurn === undefined && !this.recoveryTurnActive) ||
      this.agent === undefined
    ) return false;
    if (this.options.bridge.abortTurn === undefined && this.activeAbort === undefined) {
      return false;
    }
    this.options.bridge.abortTurn?.(this.agent);
    this.activeAbort?.abort();
    if (this.recoveryTurnActive) this.invalidateRateLimitContext();
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
    // `/compact` is a first-class app operation, not a pass-through command:
    // this path carries the mid-turn switch semantics, and the session id
    // comes from the app's session context (never derived from an active run).
    if (id === "compact") {
      const requested = compactSessionArgument(argsJson);
      const sessionId = requested ?? this.currentSessionId;
      if (requested === undefined) this.currentSessionId = sessionId;
      const bridge = this.options.bridge as CompactCapableBridge<AgentHandle>;
      if (bridge.compactSession === undefined) {
        throw new CetasApplicationError(
          "bridge_failure",
          "bridge does not support session compaction",
        );
      }
      const switchRequested = this.activeTurn !== undefined || this.recoveryTurnActive;
      this.compactInFlight = true;
      try {
        const outcome = await this.runCompactLocked(bridge, this.agent, sessionId, switchRequested);
        return compactCommandOutcomeJson(outcome);
      } finally {
        this.compactInFlight = false;
        this.waitingForCleanup = false;
      }
    }
    const agent = this.agent;
    const switchesModel = id === "model" && modelSelectionRequested(argsJson);
    if (switchesModel) await this.stopRateLimitMonitor(false);
    let outcome: string;
    try {
      outcome = await this.options.bridge.invokeCommand(agent, id, argsJson);
      if (switchesModel && commandOutcomeSucceeded(outcome)) {
        this.rateLimitContextGeneration += 1;
        this.rateLimitRecoveryEligible = false;
        this.recoveryFollowUpsQueued = 0;
        this.options.bridge.cancelPendingRateLimit(agent);
      }
    } finally {
      if (
        switchesModel &&
        (this.state as AppState) !== "shutting_down" &&
        this.agent === agent
      ) {
        this.startRateLimitMonitor(agent, this.rateLimitContextGeneration);
      }
    }
    if (commandRequestsSetupRefresh(outcome)) {
      // Setup discovery is the serialization barrier while a refresh_settings
      // outcome rebuilds provider state. Avoid a re-entrant shutdown waiting on
      // this command promise during the ready-state publication.
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
    this.compactAbort?.abort();
    this.transition("shutting_down");
    this.shutdownPromise = (async () => {
      let pendingError: unknown;
      await this.stopRateLimitMonitor(true);
      await this.stopLiveCatalogRefresh();
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

  private agentCallbacks(): AgentCallbacks {
    return {
      ...this.options.callbacks,
      observerCallback: (eventJson) => this.handleAgentObserverEvent(eventJson),
    };
  }

  private handleAgentObserverEvent(eventJson: string): void {
    let type: unknown;
    try {
      const event: unknown = JSON.parse(eventJson);
      if (typeof event === "object" && event !== null && !Array.isArray(event)) {
        type = (event as Record<string, unknown>).type;
      }
    } catch {
      // The renderer owns strict event diagnostics. Lifecycle tracking only
      // classifies known boundaries and forwards all bytes unchanged below.
    }

    if (
      type === "turn_started" &&
      this.rateLimitRecoveryEligible &&
      this.activeTurn === undefined &&
      this.state === "ready"
    ) {
      this.recoveryTurnActive = true;
      this.rateLimitRecoveryEligible = false;
      this.transition("running");
    } else if (
      type === "turn_started" &&
      this.recoveryTurnActive &&
      this.recoveryFollowUpsQueued > 0
    ) {
      // A follow-up queued during the recovery drains as its own turn; this
      // is that turn starting, not a stale event from a cancelled monitor.
      this.recoveryFollowUpsQueued -= 1;
    }
    if (type === "turn_started" && this.pendingFollowUps.length > 0) {
      // Each Agent-side follow-up drain runs as its own turn; one queue
      // entry per started turn keeps the pending mirror in sync.
      this.pendingFollowUps.shift();
      this.publish();
    }
    try {
      this.options.callbacks.observerCallback(eventJson);
    } finally {
      // A throwing observer callback must not wedge the busy state: the
      // renderer owns event diagnostics, lifecycle tracking still unwinds.
      if (
        this.recoveryTurnActive &&
        (type === "turn_completed" || type === "turn_failed")
      ) {
        // A failed recovery drops its queue; a completed one with follow-ups
        // still queued keeps the busy state until the last drain turn ends.
        if (type === "turn_failed" || this.recoveryFollowUpsQueued === 0) {
          this.recoveryTurnActive = false;
          this.recoveryFollowUpsQueued = 0;
          if ((this.state as AppState) === "running") this.transition("ready");
        }
      }
    }
  }

  private startRateLimitMonitor(
    agent: AgentHandle,
    generation = this.rateLimitContextGeneration,
  ): void {
    if (this.rateLimitMonitor !== undefined) return;
    if (this.agent !== agent || this.rateLimitContextGeneration !== generation) return;
    if (this.state !== "ready" || this.activeTurn !== undefined || this.activeCommand !== undefined) {
      this.rateLimitMonitorRestartRequest = {
        agent,
        generation,
      };
      return;
    }
    const settling = this.rateLimitMonitorSettling;
    if (settling !== undefined) {
      this.rateLimitMonitorRestartRequest = { agent, generation };
      void settling.then(() => this.flushRateLimitMonitorRestart());
      return;
    }
    this.rateLimitMonitorRestartRequest = undefined;
    this.rateLimitRecoveryEligible = true;
    const controller = new AbortController();
    const settled = Promise.resolve()
      .then(() => this.options.bridge.startRateLimitMonitor(agent, controller.signal))
      .then(
        () => {
          if (!controller.signal.aborted) {
            this.reportRateLimitMonitorFailure(
              new Error("rate-limit monitor stopped before its Agent lifetime ended"),
            );
          }
        },
        (error: unknown) => {
          if (!isRateLimitMonitorAbort(error, controller.signal)) {
            this.reportRateLimitMonitorFailure(error);
          }
        },
      );
    const monitor = { agent, controller, settled, generation };
    this.rateLimitMonitor = monitor;
    void settled.then(() => {
      if (this.rateLimitMonitor === monitor) {
        this.rateLimitMonitor = undefined;
        this.rateLimitRecoveryEligible = false;
        // A recovery turn runs inline in the monitor coroutine: when the
        // monitor dies mid-recovery (failure or host abort), no turn boundary
        // event will ever arrive, so release the busy state here.
        if (this.recoveryTurnActive && this.activeTurn === undefined) {
          this.recoveryTurnActive = false;
          this.recoveryFollowUpsQueued = 0;
          if ((this.state as AppState) === "running") this.transition("ready");
        }
      }
    });
  }

  private stopRateLimitMonitor(cancelPending: boolean): Promise<void> {
    const agent = this.agent ?? this.rateLimitMonitor?.agent;
    if (cancelPending && agent !== undefined) {
      this.options.bridge.cancelPendingRateLimit(agent);
    }
    this.rateLimitRecoveryEligible = false;
    const monitor = this.rateLimitMonitor;
    const settling = this.rateLimitMonitorSettling;
    if (monitor === undefined) return settling ?? Promise.resolve();
    this.rateLimitMonitor = undefined;
    monitor.controller.abort();
    const wait = settling === undefined
      ? monitor.settled
      : Promise.all([settling, monitor.settled]).then(() => undefined);
    this.rateLimitMonitorSettling = wait;
    void wait.then(() => {
      if (this.rateLimitMonitorSettling === wait) this.rateLimitMonitorSettling = undefined;
    });
    return wait;
  }

  private invalidateRateLimitContext(): void {
    const agent = this.agent;
    this.rateLimitContextGeneration += 1;
    this.rateLimitRecoveryEligible = false;
    this.recoveryFollowUpsQueued = 0;
    if (agent === undefined) return;
    const settled = this.stopRateLimitMonitor(true);
    const generation = this.rateLimitContextGeneration;
    void settled.then(() => {
      if (
        (this.state as AppState) === "ready" &&
        this.activeTurn === undefined &&
        this.activeCommand === undefined &&
        (this.state as AppState) !== "shutting_down" &&
        this.agent === agent &&
        this.rateLimitContextGeneration === generation
      ) {
        this.startRateLimitMonitor(agent, generation);
      }
    });
  }

  private flushRateLimitMonitorRestart(): void {
    const request = this.rateLimitMonitorRestartRequest;
    if (request === undefined) return;
    this.rateLimitMonitorRestartRequest = undefined;
    if (
      (this.state as AppState) === "shutting_down" ||
      this.agent !== request.agent ||
      this.rateLimitContextGeneration !== request.generation
    ) return;
    this.startRateLimitMonitor(request.agent, request.generation);
  }

  private reportRateLimitMonitorFailure(error: unknown): void {
    const message = `rate-limit monitor failed: ${errorMessage(error)}`;
    this.lastError = message;
    this.publish();
    try {
      this.options.callbacks.observerCallback(JSON.stringify({
        type: "custom",
        source: "cetas-js.host",
        label: "ratelimit_monitor_failed",
        data: { message },
      }));
    } catch (callbackError: unknown) {
      console.error(message, error, "observer callback failed", callbackError);
    }
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Strict parse of the live-refresh bridge summary. `refreshed` entries must
 * carry a numeric `slots`; `reason` stays optional on both statuses (the
 * MoonBit side emits it only when there is something to explain, including
 * non-fatal swap warnings on refreshed entries).
 */
function parseCatalogRefreshSummary(raw: string): CatalogRefreshSummary {
  const value: unknown = JSON.parse(raw);
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("catalog refresh summary must be an object");
  }
  const results = (value as Record<string, unknown>).results;
  if (!Array.isArray(results)) {
    throw new Error("catalog refresh summary must contain a results array");
  }
  return {
    results: results.map((entry, index) => {
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        throw new Error(`catalog refresh entry ${index} must be an object`);
      }
      const record = entry as Record<string, unknown>;
      const provider = record.provider;
      if (typeof provider !== "string") {
        throw new Error(`catalog refresh entry ${index} must carry a provider id`);
      }
      if (record.status !== "refreshed" && record.status !== "failed") {
        throw new Error(`catalog refresh entry ${index} has an unsupported status`);
      }
      const reason = record.reason;
      if (reason !== undefined && reason !== null && typeof reason !== "string") {
        throw new Error(`catalog refresh entry ${index} reason must be a string`);
      }
      if (record.status === "refreshed") {
        const slots = record.slots;
        if (typeof slots !== "number") {
          throw new Error(`catalog refresh entry ${index} must carry a slot count`);
        }
        return {
          provider,
          status: record.status,
          slots,
          ...(typeof reason === "string" ? { reason } : {}),
        };
      }
      return {
        provider,
        status: record.status,
        ...(typeof reason === "string" ? { reason } : {}),
      };
    }),
  };
}

/**
 * Optional `session_id` override for `/compact`; absence means the app's
 * session context decides (currentSessionId), never an active run id.
 */
function compactSessionArgument(argsJson: string): string | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(argsJson);
  } catch {
    return undefined;
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return undefined;
  const sessionId = (raw as Record<string, unknown>).session_id;
  return typeof sessionId === "string" && sessionId.length > 0 ? sessionId : undefined;
}

/** Typed compact outcome rendered in the CommandOutcome JSON envelope. */
function compactCommandOutcomeJson(outcome: CompactSessionOutcome): string {
  if (outcome.ok) {
    return JSON.stringify({ type: "success", structured: outcome });
  }
  return JSON.stringify({
    type: "failure",
    reason: outcome.detail ?? "compact failed",
    structured: { error_kind: outcome.errorKind },
  });
}

function isRateLimitMonitorAbort(error: unknown, signal: AbortSignal): boolean {
  if (signal.aborted) return true;
  return error instanceof Error && error.name === "AbortError";
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

function modelSelectionRequested(argsJson: string): boolean {
  let value: unknown;
  try {
    value = JSON.parse(argsJson);
  } catch {
    // The command bridge owns malformed-argument diagnostics.
    return false;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const slot = (value as Record<string, unknown>).slot;
  return typeof slot === "string" && slot.length > 0;
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
  CatalogRefreshSummary,
  CancellationToken,
} from "./types.ts";
