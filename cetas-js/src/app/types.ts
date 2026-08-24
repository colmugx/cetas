/**
 * Application-level contracts for cetas-js.
 *
 * This file deliberately has no pi-tui imports.  The terminal renderer is a
 * consumer of these snapshots; it is not allowed to own agent lifecycle or
 * provider configuration.
 */

export type AppState = "needs_setup" | "ready" | "running" | "shutting_down";

export interface CetasHostConfig {
  /** Working directory used by the session extension. */
  cwd: string;
  /** Universal Posoco runtime policy. */
  maxToolRounds: number;
  /**
   * Home directory holding all durable user state under `~/.cetas/`:
   * credentials, settings, profiles, sessions, and the global AGENTS.md
   * context lookup (`~/.cetas/agent/AGENTS.md`). Sensitive artifacts never
   * land in the project working tree (`cwd`).
   */
  home: string;
  /**
   * Permission posture for coding-agent tools. `"workspace_write"` (default)
   * auto-approves reads and gates writes/shell/unknown through a UI confirm;
   * `"readonly"` rejects every non-read tool; `"interactive"` gates every
   * side-effecting tool; `"yolo"` pre-approves everything without asking.
   * Unrecognized values fall back to `"workspace_write"`.
   */
  permissionMode?: "readonly" | "workspace_write" | "interactive" | "yolo";
}

export interface ProviderModelCapability {
  id: string;
  label: string;
  provider: string;
  model: string;
  active: boolean;
  efforts: readonly string[];
  oauth: boolean;
  /** Provider-advertised authentication methods, e.g. api_key/oauth. */
  authMethods?: readonly string[];
}

export interface ProviderAuthCapability {
  id: string;
  methods: readonly string[];
}

/**
 * Provider/router-owned setup information.  Endpoint and credential values
 * never cross this boundary; only capabilities safe for display and command
 * selection do.
 */
export interface ProviderSetupSnapshot {
  providers: readonly ProviderModelCapability[];
  oauthProviders: readonly string[];
  /** Provider-neutral authentication capabilities, including unconfigured providers. */
  authProviders?: readonly ProviderAuthCapability[];
  activeModelId?: string;
  /** Providers skipped because their catalog build failed; the rest still work. */
  warnings?: readonly string[];
}

export interface AppSnapshot {
  state: AppState;
  setup: ProviderSetupSnapshot;
  sessionId: string;
  error?: string;
}

export interface AgentCallbacks {
  observerCallback: (eventJson: string) => void;
  renderCallback: (eventJson: string) => void;
  requestCallback: (eventJson: string) => Promise<string>;
}

/** Cooperative cancellation observed by provider OAuth polling. */
export interface CancellationToken {
  isCancelled(): boolean;
}

/**
 * The only bridge surface the application needs from the MoonBit product
 * boundary.  The bridge may be backed by the generated JS module or a fake in
 * tests; neither implementation exposes Puppet, HostRuntime, catalog, or
 * journal concepts.
 */
export interface CetasAgentBridge<AgentHandle = unknown> {
  /**
   * Explicitly refresh provider-owned model catalogs. `undefined` means all
   * providers; a non-empty list refreshes only those provider ids. The bridge
   * owns the process cache, while setup discovery below remains cache-only.
   */
  refreshModelCatalogs?(
    config: CetasHostConfig,
    providers?: readonly string[],
  ): Promise<ProviderSetupSnapshot>;
  describeSetup(config: CetasHostConfig): Promise<ProviderSetupSnapshot>;
  createAgent(
    config: CetasHostConfig,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
  ): Promise<AgentHandle>;
  /**
   * Run provider-owned authentication through the extension seam.  Cetas uses
   * this path before and after an Agent exists so an unconfigured provider is
   * still reachable; successful credentials are followed by setup discovery
   * and (when needed) Agent recomposition. The provider extension persists
   * credentials and returns a normal CommandOutcome JSON string.
   */
  login?(
    config: CetasHostConfig,
    provider: string,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
    method?: string,
  ): Promise<string>;
  /**
   * Run one agent turn. `signal` aborts the turn immediately: the bridge
   * cancels the turn coroutine, which interrupts the in-flight model request,
   * and the returned Promise settles with the partial result or rejects with
   * an AbortError. Callers that never abort may omit it.
   */
  runTurn(agent: AgentHandle, prompt: string, sessionId: string, signal?: AbortSignal): Promise<string>;
  /**
   * Request an abort of the agent's active run (the host's ESC interrupt).
   * Best-effort and synchronous: the run loop observes it at its next safe
   * point, so the pending `runTurn` resolves with the partial transcript
   * rather than rejecting. Returns the enqueue outcome for diagnostics.
   */
  abortTurn?(agent: AgentHandle): string;
  /**
   * Queue a user message on the active run. The Agent drains follow-ups one
   * at a time at turn boundaries, driving a full new turn per message (each
   * surfacing as a TurnStarted observer event). Returns the raw MoonBit
   * `EnqueueOutcome` string: `Accepted(...)`, `RejectedStale(...)` when no
   * run is active, or `RejectedQueueFull(depth=...)`.
   */
  enqueueFollowUp?(agent: AgentHandle, prompt: string): string;
  shutdown(agent: AgentHandle): Promise<void>;
  listCommands(agent: AgentHandle): readonly CommandDescriptor[];
  invokeCommand(agent: AgentHandle, id: string, argsJson: string): Promise<string>;
}

export interface CommandParameter {
  name: string;
  label: string;
  description: string;
  ptype: string;
  required: boolean;
  positional: boolean;
  default?: unknown;
  choices?: readonly string[];
}

export interface CommandDescriptor {
  id: string;
  label: string;
  description: string;
  category: string;
  ctype: string;
  params: readonly CommandParameter[];
  aliases: readonly string[];
  visible: boolean;
  /** pi-tui key id (e.g. "shift+tab") declared by the extension; bound by the shell. */
  shortcut?: string;
}

export interface ApplicationError {
  readonly code:
    | "not_ready"
    | "already_running"
    | "shutting_down"
    | "invalid_state"
    | "bridge_failure";
  readonly message: string;
  readonly cause?: unknown;
}

export class CetasApplicationError extends Error implements ApplicationError {
  readonly name = "CetasApplicationError";

  constructor(
    readonly code: ApplicationError["code"],
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
  }
}
