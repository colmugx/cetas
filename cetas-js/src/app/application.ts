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
  type OperationKind,
  type OperationSnapshot,
  type ProviderSetupSnapshot,
  type SessionTitle,
  type UserInputSubmission,
} from "./types.ts";
import type { PiPackagesSummary } from "./pi-packages.ts";
import type { CompactSessionOutcome } from "./moonbit-bridge.ts";
import {
  OperationCoordinator,
  type OperationLease,
} from "./operation-coordinator.ts";
import {
  parseCoreCustom,
  type CoreOperationOrigin,
  type CoreOperationSettled,
  type CoreOperationStarted,
} from "../core-events.ts";
import { AgentBusyError } from "./agent-busy.ts";

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
  /** Per-stage deadline for shutdown drains; tests inject small values. */
  shutdownSettleTimeoutMs?: number;
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
  private readonly operations = new OperationCoordinator();
  private submissionGate: Promise<void> = Promise.resolve();
  /**
   * Esc watchdog: hard-aborts the active turn only when graceful mailbox
   * cancellation has not settled it within the grace window.
   */
  private abortWatchdog: ReturnType<typeof setTimeout> | undefined;
  private activeCommand: Promise<string> | undefined;
  /**
   * Mirror of follow-ups accepted but not yet drained by the Agent (the
   * core keeps them queued across operations and starts them at a later
   * run's boundary). Hosts render these as pending user input.
   */
  private pendingFollowUps: Array<{
    prompt: string;
    images?: readonly ImageAttachment[];
  }> = [];
  private readonly cancellation = new ApplicationCancellation();
  private shutdownPromise: Promise<void> | undefined;
  private piPackages: PiPackagesSummary | undefined;
  /**
   * Core operation projection (frozen `posoco.operation` customs). Once the
   * bridge's core has emitted any operation event, started/settled are the
   * authoritative busy truth: core-initiated operations (wakeup, resumed
   * recovery) project leases of their own, settles unlock only at
   * operation_settled (never an intermediate TurnCompleted), and the legacy
   * turn_started-as-recovery guess is retired for the process lifetime.
   */
  private coreOperationsSeen = false;
  /** operation_id → the host lease carrying that core operation. */
  private readonly operationLeases = new Map<string, OperationLease>();
  /** Lease ids begun from a core projection (settled only, never TurnCompleted). */
  private readonly projectedLeases = new Set<number>();
  /**
   * Origin of each observed core operation (frozen `operation_started`).
   * Kept per operation id so a Busy loser can re-project the incumbent with
   * its real kind — a wakeup stays a wakeup in the ownership display, a
   * foreground turn stays a turn — after the loser's own lease is gone.
   */
  private readonly coreOperationOrigins = new Map<string, CoreOperationOrigin>();
  /**
   * Settled core operation ids, bounded and insertion-ordered. A Busy loser
   * can observe the rejection only after the incumbent's `operation_settled`
   * has already been projected (settle-before-wait race); this journal is
   * what makes that wait resolve immediately instead of parking forever.
   */
  private readonly settledCoreOperations = new Set<string>();
  /**
   * Settle waiters for core operations whose projected lease has not been
   * observed (yet). Flushed by the `operation_settled` projection; purely
   * event-driven, never polled.
   */
  private readonly coreOperationWaiters = new Map<string, Array<() => void>>();
  /** Set by the shutdownBegun initializer below. */
  private signalShutdownBegun: () => void = () => undefined;
  /**
   * Resolves once shutdown has begun. Busy re-admission waits race against
   * it so retained input never outlives the application.
   */
  private readonly shutdownBegun = new Promise<void>((resolve) => {
    this.signalShutdownBegun = resolve;
  });

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

  get operationSnapshot(): OperationSnapshot {
    return this.operations.snapshot();
  }

  get rateLimitRecoveryActive(): boolean {
    return this.operations.activeKind === "recovery";
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
    return this.operations.compactPending;
  }

  private beginAgentOperation(
    kind: OperationKind,
    options: {
      abort?: AbortController;
      interruptible?: boolean;
      session?: string;
    } = {},
  ): OperationLease {
    const lease = this.operations.begin(kind, options);
    if (lease === undefined) {
      if ((this.state as AppState) === "shutting_down") {
        throw new CetasApplicationError(
          "shutting_down",
          "cannot start an Agent operation after shutdown has begun",
        );
      }
      throw new CetasApplicationError(
        "already_running",
        "another Agent operation is already running",
      );
    }
    if ((this.state as AppState) !== "shutting_down" && this.state !== "running") {
      this.transition("running");
    }
    return lease;
  }

  private finishAgentOperation(lease: OperationLease): void {
    this.operations.finish(lease);
    if (
      (this.state as AppState) === "running" &&
      !this.operations.busy &&
      !this.operations.compactPending
    ) {
      this.transition("ready");
    }
  }

  private async serializeSubmission<T>(body: () => Promise<T>): Promise<T> {
    const previous = this.submissionGate;
    let release!: () => void;
    this.submissionGate = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await body();
    } finally {
      release();
    }
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
    if (this.operations.busy || this.operations.compactPending || this.activeCommand !== undefined) {
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
    if (this.operations.busy || this.operations.compactPending || this.activeCommand !== undefined) {
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
          this.options.bridge.cancelPendingRateLimit(previousAgent);
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
        this.options.bridge.cancelPendingRateLimit(previousAgent);
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
          this.options.bridge.cancelPendingRateLimit(staleAgent);
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
   * AbortController marks cancellation and the settled promise is a shutdown
   * serialization barrier. Startup composed
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
          controller.signal,
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
      !this.operations.busy &&
      !this.operations.compactPending &&
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
      this.operations.busy ||
      this.operations.compactPending ||
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
      this.operations.busy ||
      this.operations.compactPending ||
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
   * Resume this session's interrupted turn from its persisted transcript.
   * Turn-shaped: same guards and operation lease as runTurn, but the Agent
   * replays the persisted input instead of a fresh prompt. Requires a bridge
   * that exposes resumeTurn; otherwise the typed error tells the host.
   */
  async resumeTurn(sessionId = this.currentSessionId): Promise<string> {
    if (sessionId.length === 0) {
      throw new CetasApplicationError("invalid_state", "session id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot resume a turn after shutdown has begun",
      );
    }
    if (this.startPromise !== undefined || this.activeCommand !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        this.startPromise !== undefined
          ? "cannot resume a turn while setup discovery is in progress"
          : "cannot resume a turn while a command is running",
      );
    }
    if (this.state === "needs_setup" || this.agent === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "no model provider is configured; use /model or /login [provider] [method] to complete setup",
      );
    }
    if (this.operations.busy || this.operations.compactPending) {
      throw new CetasApplicationError(
        "already_running",
        "a turn is already running",
      );
    }
    if (this.options.bridge.resumeTurn === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "this bridge does not expose turn resume",
      );
    }

    this.currentSessionId = sessionId;
    const agent = this.agent;
    const abort = new AbortController();
    const lease = this.beginAgentOperation("turn", {
      abort,
      interruptible: true,
      session: sessionId,
    });
    this.options.bridge.cancelPendingRateLimit(agent);
    try {
      await Promise.resolve();
      return await this.options.bridge.resumeTurn(agent, sessionId, abort.signal);
    } catch (error: unknown) {
      this.lastError = errorMessage(error);
      this.publish();
      throw error;
    } finally {
      this.operations.markFinalizing(lease);
      this.clearAbortWatchdog();
      this.finishAgentOperation(lease);
    }
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

  /**
   * Execute one turn through the single long-lived Agent handle.
   *
   * A lost core admission is not a failed turn: the prompt never reached the
   * model, so it stays retained here. The loser waits for the incumbent core
   * operation's `operation_settled` boundary (event-driven — the wait races
   * shutdown, never polls), then re-attempts admission. Nothing core already
   * admitted is ever re-executed: only a prompt core rejected with Busy is
   * ever sent twice.
   */
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
    if (
      this.operations.busy ||
      this.operations.compactPending
    ) {
      throw new CetasApplicationError(
        "already_running",
        "a turn is already running",
      );
    }

    this.currentSessionId = sessionId;
    while (true) {
      if ((this.state as AppState) === "shutting_down") {
        throw new CetasApplicationError(
          "shutting_down",
          "cannot run a turn after shutdown has begun",
        );
      }
      if ((this.state as AppState) === "needs_setup" || this.agent === undefined) {
        throw new CetasApplicationError(
          "not_ready",
          "no model provider is configured; use /model or /login [provider] [method] to complete setup",
        );
      }
      if (this.operations.busy || this.operations.compactPending) {
        // Retained, never dropped: wait for the current owner (host
        // operation, projected core operation, or compact switch) to settle,
        // then re-attempt admission.
        await this.operations.waitUntilAvailable();
        continue;
      }
      const attempt = await this.attemptTurnAdmission(prompt, sessionId, images);
      if ("transcript" in attempt) return attempt.transcript;
      // Lost admission. Correlate the reservation with the incumbent so busy
      // truth and the wakeup-vs-foreground ownership display follow the real
      // owner, wait for THAT operation's settled boundary, and re-admit.
      this.projectBusyIncumbent(attempt);
      await this.waitForCoreOperationOrShutdown(attempt.operationId);
    }
  }

  /**
   * One admission attempt for a retained prompt. Resolves the transcript
   * when the turn ran; resolves the typed Busy envelope when core admitted
   * another operation first (nothing ran in that case). Every other error
   * records `lastError` and rejects.
   */
  private async attemptTurnAdmission(
    prompt: string,
    sessionId: string,
    images: readonly ImageAttachment[] | undefined,
  ): Promise<{ transcript: string } | AgentBusyError> {
    const agent = this.agent as AgentHandle;
    const abort = new AbortController();
    const lease = this.beginAgentOperation("turn", {
      abort,
      interruptible: true,
      session: sessionId,
    });
    this.options.bridge.cancelPendingRateLimit(agent);
    try {
      // The operation lease is installed before any bridge callback can
      // re-enter the host. The microtask preserves that ordering for bridge
      // implementations that synchronously publish observer events.
      await Promise.resolve();
      return {
        transcript: await this.options.bridge.runTurn(
          agent,
          prompt,
          sessionId,
          abort.signal,
          images,
        ),
      };
    } catch (error: unknown) {
      if (error instanceof AgentBusyError) {
        // Admission was lost before anything ran; the caller retains the
        // prompt and waits for the incumbent's settled boundary.
        return error;
      }
      this.lastError = errorMessage(error);
      this.publish();
      throw error;
    } finally {
      this.operations.markFinalizing(lease);
      this.clearAbortWatchdog();
      this.finishAgentOperation(lease);
    }
  }

  /**
   * Adopt the incumbent core operation that won admission against this
   * host's lost turn. Its `operation_started` usually arrived while the
   * losing lease was still active, so the projection can point at a lease
   * that is already finished — re-project it from the recorded origin so
   * busy truth and the wakeup-vs-foreground ownership display follow the
   * real owner until its settled boundary. No-op when a live lease already
   * carries the operation, when it has already settled (settle-before-wait
   * race), when another operation owns the coordinator, or when its started
   * event has not been observed yet (that event will project it with the
   * real origin).
   */
  private projectBusyIncumbent(busy: AgentBusyError): void {
    if ((this.state as AppState) === "shutting_down") return;
    if (this.settledCoreOperations.has(busy.operationId)) return;
    if (this.operations.busy || this.operations.compactPending) return;
    const associated = this.operationLeases.get(busy.operationId);
    if (
      associated !== undefined &&
      this.operations.activeLease?.id === associated.id
    ) {
      return;
    }
    const origin = this.coreOperationOrigins.get(busy.operationId);
    if (origin === undefined) return;
    if (associated !== undefined) this.operationLeases.delete(busy.operationId);
    const lease = this.operations.begin(kindForOrigin(origin), {
      projected: true,
      interruptible: this.options.bridge.abortTurn !== undefined,
      session: busy.session,
    });
    if (lease === undefined) return;
    this.operationLeases.set(busy.operationId, lease);
    this.projectedLeases.add(lease.id);
    if (this.state === "ready") this.transition("running");
  }

  /**
   * Resolve once the core operation has passed its settled boundary. The
   * settle notification is the frozen `operation_settled` projection — the
   * wait is purely event-driven, and a settle that already happened resolves
   * immediately instead of parking (settle-before-wait race).
   */
  private async waitForCoreOperationSettled(operationId: string): Promise<void> {
    if (this.settledCoreOperations.has(operationId)) return;
    const lease = this.operationLeases.get(operationId);
    if (lease !== undefined) {
      await lease.settled;
      return;
    }
    await new Promise<void>((resolve) => {
      const waiters = this.coreOperationWaiters.get(operationId);
      if (waiters === undefined) {
        this.coreOperationWaiters.set(operationId, [resolve]);
      } else {
        waiters.push(resolve);
      }
    });
  }

  /**
   * Wait for one core operation's settled boundary, racing shutdown so
   * retained input never outlives the application.
   */
  private async waitForCoreOperationOrShutdown(operationId: string): Promise<void> {
    const outcome = await Promise.race([
      this.waitForCoreOperationSettled(operationId).then(
        () => "settled" as const,
      ),
      this.shutdownBegun.then(() => "shutdown" as const),
    ]);
    if (outcome === "shutdown") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot re-admit input after shutdown has begun",
      );
    }
  }

  /**
   * Atomic user-input admission. The application, not the renderer, decides
   * whether input becomes an Agent follow-up or the next fresh turn. A stale
   * lower-layer run lease waits for the owning host operation to finalize
   * before retrying; it is never treated as proof that the host is idle.
   */
  async submitUserInput(
    prompt: string,
    sessionId = this.currentSessionId,
    images?: readonly ImageAttachment[],
  ): Promise<UserInputSubmission> {
    if (prompt.length === 0) {
      throw new CetasApplicationError("invalid_state", "prompt must not be empty");
    }
    if (sessionId.length === 0) {
      throw new CetasApplicationError("invalid_state", "session id must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot submit input after shutdown has begun",
      );
    }
    if (this.startPromise !== undefined || this.activeCommand !== undefined) {
      throw new CetasApplicationError(
        "already_running",
        this.startPromise !== undefined
          ? "cannot submit input while setup discovery is in progress"
          : "cannot submit input while a command is running",
      );
    }
    if (this.state === "needs_setup" || this.agent === undefined) {
      throw new CetasApplicationError(
        "not_ready",
        "no model provider is configured; use /model or /login [provider] [method] to complete setup",
      );
    }

    return this.serializeSubmission(async () => {
      while (true) {
        if ((this.state as AppState) === "shutting_down") {
          throw new CetasApplicationError(
            "shutting_down",
            "cannot submit input after shutdown has begun",
          );
        }
        const operation = this.operations.snapshot();
        if (operation.busy) {
          // A follow-up is legitimate only for a running ordinary run of the
          // SAME session (host turn/recovery or a projected core wakeup).
          // Anything else — a compact switch, a cancelling/finalizing phase,
          // or an operation on another session — waits for that operation's
          // settled boundary (projected leases settle at operation_settled,
          // after the full core drain) and retries admission; the input is
          // never dropped and never resubmitted once admitted.
          if (
            operation.session === sessionId &&
            !operation.compactPending &&
            operation.phase === "running" &&
            (operation.kind === "turn" ||
              operation.kind === "recovery" ||
              operation.kind === "wakeup")
          ) {
            const queued = this.queueFollowUp(prompt, images);
            if (queued === "accepted") return { kind: "queued" };
            if (queued === "full") return { kind: "full" };
            // RejectedStale is a lower-layer boundary race. Wait for the
            // operation lease that still owns host state, then retry admission.
          }
          await this.operations.waitForActiveToSettle();
          continue;
        }
        if (operation.compactPending) {
          await this.operations.waitUntilAvailable();
          continue;
        }
        const completion = this.runTurn(prompt, sessionId, images);
        return { kind: "started", completion };
      }
    });
  }

  /** Queue a user message on the active Agent run. */
  queueFollowUp(
    prompt: string,
    images?: readonly ImageAttachment[],
  ): "accepted" | "stale" | "full" {
    if (prompt.length === 0) {
      throw new CetasApplicationError("invalid_state", "prompt must not be empty");
    }
    if (this.state === "shutting_down") {
      throw new CetasApplicationError(
        "shutting_down",
        "cannot queue a message after shutdown has begun",
      );
    }
    const activeKind = this.operations.activeKind;
    if (
      (activeKind !== "turn" && activeKind !== "recovery" && activeKind !== "wakeup") ||
      this.agent === undefined
    ) {
      throw new CetasApplicationError("invalid_state", "no turn is active; use runTurn");
    }
    if (this.options.bridge.enqueueFollowUp === undefined) {
      throw new CetasApplicationError("bridge_failure", "bridge does not support follow-up queuing");
    }
    const raw = this.options.bridge.enqueueFollowUp(this.agent, prompt, images);
    if (raw.startsWith("Accepted")) {
      if (activeKind === "recovery") this.operations.incrementRecoveryFollowUp();
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
    if (this.activeCommand !== undefined) {
      // The documented switch contract: while another compact owns the
      // interrupt/finalize/cleanup sequence, say so instead of a generic
      // busy label (mirrors invokeCommand's waiting-for-cleanup branch).
      throw new CetasApplicationError(
        "already_running",
        this.operations.compactPending
          ? "waiting for the interrupted operation to finish cleanup before starting the compact"
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
    this.currentSessionId = sessionId;
    const compactPromise = Promise.resolve().then(() =>
      this.runCompactLocked(bridge, agent, sessionId),
    );
    const lock = compactPromise as unknown as Promise<string>;
    this.activeCommand = lock;
    try {
      return await compactPromise;
    } finally {
      if (this.activeCommand === lock) this.activeCommand = undefined;
    }
  }

  /** Compact body; the caller owns the activeCommand lock. */
  private async runCompactLocked(
    bridge: CompactCapableBridge<AgentHandle>,
    agent: AgentHandle,
    sessionId: string,
  ): Promise<CompactSessionOutcome> {
    const request = this.operations.beginCompactRequest();
    if (request === undefined) {
      throw new CetasApplicationError(
        "already_running",
        "another compact operation is already pending",
      );
    }
    try {
      if (this.operations.busy) {
        this.publish();
        this.interruptActiveTurn();
        await this.waitForActiveOperationFinalize();
      }
      if (request.controller.signal.aborted) {
        return {
          ok: false,
          errorKind: "cancelled",
          detail: "compact cancelled",
        };
      }
      if (this.agent !== agent || (this.state as AppState) === "shutting_down") {
        return {
          ok: false,
          errorKind: "error",
          detail: "compact abandoned: the agent was replaced during cleanup",
        };
      }

      const lease = this.beginAgentOperation("compact", {
        abort: request.controller,
        interruptible: true,
        session: sessionId,
      });
      try {
        this.options.bridge.cancelPendingRateLimit(agent);
        if (request.controller.signal.aborted) {
          return {
            ok: false,
            errorKind: "cancelled",
            detail: "compact cancelled",
          };
        }
        return await bridge.compactSession!(
          agent,
          sessionId,
          request.controller.signal,
        );
      } finally {
        this.operations.markFinalizing(lease);
        this.finishAgentOperation(lease);
      }
    } finally {
      this.operations.endCompactRequest(request);
      if (
        (this.state as AppState) === "running" &&
        !this.operations.busy &&
        !this.operations.compactPending
      ) {
        this.transition("ready");
      }
    }
  }

  /** Wait for the current operation lease to finalize; never poll flags. */
  private async waitForActiveOperationFinalize(timeoutMs = 5000): Promise<void> {
    const pending = this.operations.activeSettled;
    if (pending === undefined) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        pending,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => {
            reject(
              new CetasApplicationError(
                "already_running",
                "timed out waiting for the interrupted operation to finish cleanup",
              ),
            );
          }, timeoutMs);
          timer.unref?.();
        }),
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
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
    if (this.operations.busy || this.operations.compactPending) {
      // Allowlisted commands only touch host-side policy state (e.g.
      // PermissionPolicy's mutable mode, re-read before every tool call), so
      // they are safe to invoke mid-turn. `/compact` is likewise admitted:
      // it owns mid-turn switch semantics (interrupt → finalize → compact).
      // Everything else still waits.
      if (!MID_TURN_COMMANDS.has(id) && id !== "compact") {
        throw new CetasApplicationError(
          "already_running",
          this.operations.compactPending || this.operations.activePhase === "cancelling"
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
        this.operations.compactPending
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
    }
  }

  /** Request cooperative cancellation of the active provider command. */
  cancelCurrentOperation(): boolean {
    if (this.activeCommand === undefined) return false;
    this.cancellation.cancel();
    return true;
  }

  /**
   * Request cancellation of the application-owned Agent operation. The
   * coordinator is the authority; callers never need a renderer-local busy
   * flag. Turn/recovery first request the Agent mailbox abort and retain the
   * hard AbortController watchdog. Compact owns its request AbortController.
   */
  interruptActiveTurn(): boolean {
    const active = this.operations.activeLease;
    if (active === undefined) {
      return this.operations.cancelCompactRequest();
    }
    if (this.agent === undefined) return false;

    const abort = this.operations.activeAbort;
    if (
      active.kind !== "compact" &&
      this.options.bridge.abortTurn === undefined &&
      abort === undefined
    ) {
      return false;
    }

    // Cancellation is a state transition, not an edge-triggered side effect:
    // repeated ESC/shutdown requests consume the same operation without
    // re-sending mailbox aborts or postponing the hard-abort watchdog.
    if (!this.operations.requestCancellation(active)) return true;

    if (active.kind === "compact") {
      abort?.abort();
      this.operations.cancelCompactRequest();
      return true;
    }

    this.options.bridge.abortTurn?.(this.agent);
    if (abort !== undefined && !abort.signal.aborted) {
      if (this.abortWatchdog !== undefined) clearTimeout(this.abortWatchdog);
      this.abortWatchdog = setTimeout(() => {
        this.abortWatchdog = undefined;
        abort.abort();
      }, 1500);
      this.abortWatchdog.unref?.();
    }
    if (active.kind === "recovery") this.invalidateRateLimitContext();
    return true;
  }

  /** Clear a pending Esc watchdog once the turn it guarded has settled. */
  private clearAbortWatchdog(): void {
    if (this.abortWatchdog !== undefined) {
      clearTimeout(this.abortWatchdog);
      this.abortWatchdog = undefined;
    }
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
      const outcome = await this.runCompactLocked(bridge, this.agent, sessionId);
      return compactCommandOutcomeJson(outcome);
    }
    const agent = this.agent;
    const switchesModel = id === "model" && modelSelectionRequested(argsJson);
    // A deliberate model switch supersedes any scheduled retry before the
    // router mutates; the Fuwaroid runtime remains alive, only stale tickets
    // are invalidated.
    if (switchesModel) {
      this.operations.clearRecoveryFollowUps();
      this.options.bridge.cancelPendingRateLimit(agent);
    }
    const outcome = await this.options.bridge.invokeCommand(agent, id, argsJson);
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
   * Shutdown is idempotent and terminal. Active Agent work is cancelled
   * before it is drained, and every drain stage is bounded — live refresh,
   * in-flight setup/command promises, and the Agent barrier alike — so
   * Ctrl+C can never hang on a host promise that never settles. Agent
   * shutdown remains the final lifecycle barrier; its own timeout is a
   * `shutting_down` failure, not a skip.
   */
  shutdown(): Promise<void> {
    if (this.shutdownPromise !== undefined) return this.shutdownPromise;
    const pendingSetup = this.startPromise;
    const pendingCommand = this.activeCommand;
    if (pendingCommand !== undefined) this.cancellation.cancel();

    this.operations.markShuttingDown();
    this.transition("shutting_down");
    // Busy re-admission waits race against this signal: retained input is
    // dropped (as a typed shutting_down error) the moment shutdown begins.
    this.signalShutdownBegun();
    this.interruptActiveTurn();

    this.shutdownPromise = (async () => {
      const timeoutMs = this.options.shutdownSettleTimeoutMs ?? 5000;
      const shutdownTimeout = (stage: string) =>
        new CetasApplicationError(
          "shutting_down",
          `shutdown timed out waiting for the ${stage} to settle`,
        );
      let pendingError: unknown;
      if (this.agent !== undefined) {
        this.options.bridge.cancelPendingRateLimit(this.agent);
      }
      const live = await this.settleWithin(
        this.stopLiveCatalogRefresh(),
        timeoutMs,
      );
      if (!live.settled) {
        pendingError ??= shutdownTimeout("live model catalog refresh");
      } else if (live.failed) {
        pendingError ??= live.error;
      }

      try {
        await this.waitForActiveOperationFinalize(timeoutMs);
      } catch (error: unknown) {
        pendingError ??= error;
      }

      for (const pending of [pendingSetup, pendingCommand]) {
        if (pending === undefined) continue;
        const outcome = await this.settleWithin(pending, timeoutMs);
        if (!outcome.settled) {
          pendingError ??= shutdownTimeout("pending application operation");
        } else if (outcome.failed) {
          pendingError ??= outcome.error;
        }
      }
      if (this.agent !== undefined) {
        const agent = this.agent;
        this.agent = undefined;
        const outcome = await this.settleWithin(
          this.options.bridge.shutdown(agent),
          timeoutMs,
        );
        if (!outcome.settled) {
          // The Agent barrier refusing to settle is itself a lifecycle
          // failure — report it instead of hanging the host.
          throw shutdownTimeout("agent shutdown");
        }
        if (outcome.failed) {
          // Agent shutdown is the stronger lifecycle failure.
          throw outcome.error;
        }
      }
      if (pendingError !== undefined) throw pendingError;
    })();
    return this.shutdownPromise;
  }

  /**
   * Race a shutdown-stage promise against a deadline. The result records
   * whether the promise settled and, when it failed, its error; a promise
   * that settles late (after the deadline won) stays handled so it can
   * never surface as an unhandled rejection during teardown.
   */
  private async settleWithin(
    pending: Promise<unknown>,
    timeoutMs: number,
  ): Promise<{ settled: boolean; failed: boolean; error?: unknown }> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        Promise.resolve(pending).then(
          () => ({ settled: true, failed: false }) as const,
          (error: unknown) =>
            ({ settled: true, failed: true, error }) as const,
        ),
        new Promise<{ settled: false; failed: false }>((resolve) => {
          timer = setTimeout(() => resolve({ settled: false, failed: false }), timeoutMs);
          timer.unref?.();
        }),
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
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

  /**
   * Project one frozen `posoco.operation` started event. When a host lease
   * already owns the run, the core operation associates with it; otherwise
   * the operation is core-initiated (wakeup, runtime-owned resume) and gets
   * a projected lease so busy truth survives without a host promise. The
   * origin maps directly — only the legacy protocol (no operation events)
   * guesses "recovery".
   */
  private projectCoreOperationStarted(started: CoreOperationStarted): void {
    this.coreOperationsSeen = true;
    this.coreOperationOrigins.set(started.operation_id, started.origin);
    const active = this.operations.activeLease;
    if (active !== undefined) {
      this.operationLeases.set(started.operation_id, active);
      return;
    }
    if ((this.state as AppState) === "shutting_down") return;
    const lease = this.operations.begin(kindForOrigin(started.origin), {
      projected: true,
      interruptible: this.options.bridge.abortTurn !== undefined,
      session: started.session,
    });
    if (lease === undefined) return;
    this.operationLeases.set(started.operation_id, lease);
    this.projectedLeases.add(lease.id);
    if (this.state === "ready") this.transition("running");
  }

  /**
   * Settle the lease carrying `settled.operation_id`. The settled boundary
   * is the core's full drain + cleanup; until it arrives the projected lease
   * stays busy, whatever intermediate turn events fire. A lease the host
   * already finalized through its own promise resolution is left alone.
   *
   * The settle is journaled and every waiter for the operation is flushed
   * BEFORE the lease bookkeeping: Busy losers may register their wait after
   * this projection ran (settle-before-wait), and lease-less settles (the
   * started projection was never observed) must still unlock them.
   */
  private projectCoreOperationSettled(settled: CoreOperationSettled): void {
    this.coreOperationsSeen = true;
    this.coreOperationOrigins.delete(settled.operation_id);
    this.settledCoreOperations.delete(settled.operation_id);
    this.settledCoreOperations.add(settled.operation_id);
    while (this.settledCoreOperations.size > 32) {
      const oldest = this.settledCoreOperations.values().next();
      if (oldest.done) break;
      this.settledCoreOperations.delete(oldest.value);
    }
    const waiters = this.coreOperationWaiters.get(settled.operation_id);
    if (waiters !== undefined) {
      this.coreOperationWaiters.delete(settled.operation_id);
      for (const waiter of waiters) waiter();
    }
    const lease = this.operationLeases.get(settled.operation_id);
    if (lease === undefined) return;
    this.operationLeases.delete(settled.operation_id);
    const active = this.operations.activeLease;
    if (active === undefined || active.id !== lease.id) return;
    this.operations.markFinalizing(lease);
    this.clearAbortWatchdog();
    this.finishAgentOperation(lease);
  }

  private handleAgentObserverEvent(eventJson: string): void {
    let type: unknown;
    let coreCustom: { source: string; label: string; data: unknown } | undefined;
    try {
      const event: unknown = JSON.parse(eventJson);
      if (typeof event === "object" && event !== null && !Array.isArray(event)) {
        const record = event as Record<string, unknown>;
        type = record.type;
        if (
          record.type === "custom" &&
          typeof record.source === "string" &&
          typeof record.label === "string"
        ) {
          coreCustom = {
            source: record.source,
            label: record.label,
            data: record.data,
          };
        }
      }
    } catch {
      // The renderer owns strict event diagnostics. Lifecycle tracking only
      // classifies known boundaries and forwards all bytes unchanged below.
    }

    if (coreCustom !== undefined) {
      const core = parseCoreCustom(
        coreCustom.source,
        coreCustom.label,
        coreCustom.data,
      );
      if (core.kind === "operation") {
        if (core.event.phase === "started") {
          this.projectCoreOperationStarted(core.event);
        } else {
          this.projectCoreOperationSettled(core.event);
        }
      }
      // wakeup/tasks/decision customs are display projections: the observer
      // callback below forwards them to the renderer unchanged.
    }

    // Legacy protocol only (no operation events observed): an idle
    // turn_started used to be the only signal of a runtime-owned recovery.
    // Under the operation protocol every admission announces itself, so
    // autonomous turns must never be guessed as recovery.
    if (
      type === "turn_started" &&
      !this.coreOperationsSeen &&
      !this.operations.busy &&
      !this.operations.compactPending &&
      this.state === "ready"
    ) {
      const lease = this.operations.begin("recovery", {
        interruptible: this.options.bridge.abortTurn !== undefined,
        session: this.currentSessionId,
      });
      if (lease !== undefined) {
        this.transition("running");
      }
    } else if (
      type === "turn_started" &&
      this.operations.activeKind === "recovery" &&
      this.operations.recoveryFollowUpsQueued > 0
    ) {
      this.operations.consumeRecoveryFollowUpStart();
    }
    if (type === "turn_started" && this.pendingFollowUps.length > 0) {
      this.pendingFollowUps.shift();
      this.publish();
    }

    try {
      this.options.callbacks.observerCallback(eventJson);
    } finally {
      if (
        this.operations.activeKind === "recovery" &&
        (type === "turn_completed" || type === "turn_failed")
      ) {
        const lease = this.operations.activeLease;
        // A core-projected recovery ends at operation_settled — the full
        // follow-up drain and cleanup — never at the first TurnCompleted.
        if (lease !== undefined && !this.projectedLeases.has(lease.id)) {
          if (
            type === "turn_failed" ||
            this.operations.recoveryFollowUpsQueued === 0
          ) {
            this.operations.clearRecoveryFollowUps();
            this.operations.markFinalizing(lease);
            this.finishAgentOperation(lease);
          }
        }
      }
    }
  }

  private invalidateRateLimitContext(): void {
    this.operations.clearRecoveryFollowUps();
    if (this.agent !== undefined) {
      this.options.bridge.cancelPendingRateLimit(this.agent);
    }
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Core origin → host lease vocabulary. `resume` maps to the host's
 * recovery kind (runtime-owned resumed turn, rate-limit retries included);
 * a wakeup keeps its own kind so autonomous environment turns are never
 * mislabeled as recovery.
 */
function kindForOrigin(origin: CoreOperationOrigin): OperationKind {
  switch (origin) {
    case "resume":
      return "recovery";
    case "wakeup":
      return "wakeup";
    case "compact":
      return "compact";
    case "turn":
      return "turn";
  }
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
