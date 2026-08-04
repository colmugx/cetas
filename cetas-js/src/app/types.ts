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
  /** Home directory for AGENTS.md global lookup (~/.cetas/agent/AGENTS.md). */
  home: string;
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
  runTurn(agent: AgentHandle, prompt: string, sessionId: string): Promise<string>;
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
