import * as moonbit from "mbt:colmugx/cetas-js/lib";
import { join } from "node:path";
import { scanAndLoadPiPackages, type PiPackagesSummary } from "./pi-packages.ts";
import type {
  AgentCallbacks,
  CetasAgentBridge,
  CetasHostConfig,
  CancellationToken,
  CommandDescriptor,
  ImageAttachment,
  ProviderAuthCapability,
  ProviderSetupSnapshot,
} from "./types.ts";

const rateLimitExports = moonbit as unknown as {
  cetas_js_start_ratelimit_monitor(
    agent: moonbit.CetasJsAgent,
    signal: AbortSignal,
  ): Promise<void>;
  cetas_js_cancel_pending_ratelimit(agent: moonbit.CetasJsAgent): void;
};

/**
 * Adapter for the generated MoonBit boundary. Provider settings and
 * credentials remain behind the MoonBit/provider extension seam; this TS
 * layer only carries capability snapshots and command JSON.
 */
export class MoonbitCetasAgentBridge implements CetasAgentBridge {
  private readonly configValue: moonbit.CetasJsConfig;
  private readonly runtimeValue: moonbit.CetasJsRuntime;
  private readonly loadedPiEntries = new Set<string>();
  private toolCatalogValue: Readonly<Record<string, string>> = {};
  private piPackagesValue: PiPackagesSummary | undefined;

  constructor(config: CetasHostConfig) {
    this.configValue = new moonbit.CetasJsConfig(
      config.cwd,
      config.maxToolRounds,
      config.home,
      config.permissionMode ?? "workspace_write",
      // Empty string is the bridge's "not chosen" convention; the MoonBit
      // constructor then falls back to `<home>/.cetas/sessions`.
      config.sessionsDir ?? "",
      // Same empty-string convention for the /help host note.
      config.hostHelpNote ?? "",
    );
    this.runtimeValue = new moonbit.CetasJsRuntime(this.configValue);
  }

  /**
   * Tool name → owning extension id, snapshotted at agent creation. Empty
   * until `createAgent` resolves; parsing failures degrade to `{}`.
   */
  get toolLabels(): Readonly<Record<string, string>> {
    return this.toolCatalogValue;
  }

  async describeSetup(_config: CetasHostConfig): Promise<ProviderSetupSnapshot> {
    const raw = await moonbit.cetas_js_runtime_describe_setup(this.runtimeValue);
    return parseProviderSetup(raw);
  }

  async refreshModelCatalogs(
    _config: CetasHostConfig,
    providers?: readonly string[],
  ): Promise<ProviderSetupSnapshot> {
    const providerIdsJson = providers === undefined ? "" : JSON.stringify([...providers]);
    const raw = await moonbit.cetas_js_runtime_refresh_model_catalogs(this.runtimeValue, providerIdsJson);
    return parseProviderSetup(raw);
  }

  /**
   * Scan `<home>/.cetas/pi-packages` and load each pi extension entry into
   * this runtime. Per-package failures are collected by the loader; this
   * never throws. The last summary is exposed as `piPackages` for the host
   * to render as a notice — stdout belongs to the TUI.
   */
  async loadPiPackages(home: string): Promise<PiPackagesSummary> {
    const summary = await scanAndLoadPiPackages(
      join(home, ".cetas", "pi-packages"),
      async (entryFileUrl) => {
        const raw = await moonbit.cetas_js_pi_load_package(this.runtimeValue, entryFileUrl);
        const value: unknown = JSON.parse(raw);
        if (!isRecord(value) || value.ok !== true) {
          const message = isRecord(value) && typeof value.error === "string"
            ? value.error
            : "pi package load failed";
          throw new Error(message);
        }
      },
      this.loadedPiEntries,
    );
    this.piPackagesValue = summary;
    return summary;
  }

  get piPackages(): PiPackagesSummary | undefined {
    return this.piPackagesValue;
  }

  async createAgent(
    config: CetasHostConfig,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
  ): Promise<unknown> {
    // Pi tools must exist before composition so the agent's catalog sees them.
    await this.loadPiPackages(config.home);
    const agent = await moonbit.cetas_js_runtime_create_agent(
      this.runtimeValue,
      callbacks.observerCallback,
      callbacks.renderCallback,
      callbacks.requestCallback,
      () => cancellation?.isCancelled() ?? false,
    );
    this.toolCatalogValue = snapshotToolCatalog(agent);
    return agent;
  }

  login(
    _config: CetasHostConfig,
    provider: string,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
    method?: string,
  ): Promise<string> {
    return moonbit.cetas_js_runtime_login_provider(
      this.runtimeValue,
      provider,
      callbacks.observerCallback,
      callbacks.requestCallback,
      () => cancellation?.isCancelled() ?? false,
      method ?? "",
    );
  }

  runTurn(
    agent: unknown,
    prompt: string,
    sessionId: string,
    signal?: AbortSignal,
    images?: readonly ImageAttachment[],
  ): Promise<string> {
    // The MoonBit export takes the signal positionally; a fresh never-aborted
    // controller keeps signal-less callers (tests, smoke) on the same path.
    return moonbit.cetas_js_run_turn(
      agent as moonbit.CetasJsAgent,
      prompt,
      imagesJsonFor(images),
      sessionId,
      signal ?? new AbortController().signal,
    );
  }

  startRateLimitMonitor(agent: unknown, signal: AbortSignal): Promise<void> {
    return rateLimitExports.cetas_js_start_ratelimit_monitor(
      agent as moonbit.CetasJsAgent,
      signal,
    );
  }

  cancelPendingRateLimit(agent: unknown): void {
    rateLimitExports.cetas_js_cancel_pending_ratelimit(agent as moonbit.CetasJsAgent);
  }

  activeModelSupportsImages(agent: unknown): boolean {
    return moonbit.cetas_js_active_model_supports_images(agent as moonbit.CetasJsAgent) === "true";
  }

  abortTurn(agent: unknown): string {
    return moonbit.cetas_js_abort_turn(agent as moonbit.CetasJsAgent);
  }

  enqueueFollowUp(
    agent: unknown,
    prompt: string,
    images?: readonly ImageAttachment[],
  ): string {
    return moonbit.cetas_js_enqueue_follow_up(agent as moonbit.CetasJsAgent, prompt, imagesJsonFor(images));
  }

  shutdown(agent: unknown): Promise<void> {
    return moonbit.cetas_js_shutdown(agent as moonbit.CetasJsAgent);
  }

  listCommands(agent: unknown): readonly CommandDescriptor[] {
    return parseCommandList(moonbit.cetas_js_list_commands(agent as moonbit.CetasJsAgent));
  }

  invokeCommand(agent: unknown, id: string, argsJson: string): Promise<string> {
    return moonbit.cetas_js_invoke_command(agent as moonbit.CetasJsAgent, id, argsJson);
  }

  async rewind(agent: unknown, sessionId: string, fromIndex: number): Promise<void> {
    // The MoonBit export encodes storage failures in its JSON envelope
    // instead of rejecting; surface them as rejections so callers get the
    // runTurn-style error path.
    const raw = await moonbit.cetas_js_rewind(agent as moonbit.CetasJsAgent, sessionId, fromIndex);
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) throw new Error("rewind response must be an object");
    if (value.ok !== true) {
      const message = typeof value.error === "string" ? value.error : "rewind failed";
      throw new Error(message);
    }
  }

  listWorkspaceFiles(_config: CetasHostConfig): Promise<string> {
    return moonbit.cetas_js_list_workspace_files(this.configValue);
  }
}

function imagesJsonFor(images?: readonly ImageAttachment[]): string {
  return images === undefined || images.length === 0
    ? "[]"
    : JSON.stringify(images);
}

// Intentionally lenient unlike the strict parsers below: the catalog only
// feeds display titles, so any failure degrades to an empty mapping instead
// of failing agent creation.
function snapshotToolCatalog(agent: moonbit.CetasJsAgent): Record<string, string> {
  try {
    const value: unknown = JSON.parse(moonbit.cetas_js_tool_catalog(agent));
    if (!isRecord(value)) return {};
    const catalog: Record<string, string> = {};
    for (const [name, extId] of Object.entries(value)) {
      if (typeof extId === "string") catalog[name] = extId;
    }
    return catalog;
  } catch {
    return {};
  }
}

function parseProviderSetup(raw: string): ProviderSetupSnapshot {
  const value: unknown = JSON.parse(raw);
  if (!isRecord(value)) throw new Error("provider setup response must be an object");
  const providersRaw = value.providers;
  const oauthRaw = value.oauthProviders;
  if (!Array.isArray(providersRaw)) {
    throw new Error("provider setup response must contain a providers array");
  }
  if (oauthRaw !== undefined && !Array.isArray(oauthRaw)) {
    throw new Error("provider setup response.oauthProviders must be an array");
  }
  const authProviders = value.authProviders === undefined
    ? undefined
    : parseAuthProviders(value.authProviders);
  const oauthProviders = oauthRaw === undefined
    ? (authProviders ?? [])
      .filter((entry) => entry.methods.includes("oauth"))
      .map((entry) => entry.id)
    : oauthRaw.map((entry, index) => requireString(entry, `oauthProviders[${index}]`));
  return {
    providers: providersRaw.map((entry, index) => parseProvider(entry, index)),
    oauthProviders,
    ...(authProviders === undefined ? {} : { authProviders }),
    ...(value.warnings === undefined || value.warnings === null
      ? {}
      : {
          warnings: (value.warnings as unknown[]).map((entry, index) =>
            requireString(entry, `warnings[${index}]`)),
        }),
    ...(value.activeModelId === undefined
      ? {}
      : { activeModelId: requireString(value.activeModelId, "activeModelId") }),
  };
}

function parseAuthProviders(value: unknown): readonly ProviderAuthCapability[] {
  if (!Array.isArray(value)) throw new Error("provider setup response.authProviders must be an array");
  return value.map((entry, index) => {
    const path = `authProviders[${index}]`;
    const record = requireRecord(entry, path);
    const methods = record.methods;
    if (!Array.isArray(methods)) throw new Error(`${path}.methods must be an array`);
    return {
      id: requireString(record.id ?? record.provider, `${path}.id`),
      methods: methods.map((method, methodIndex) =>
        requireString(method, `${path}.methods[${methodIndex}]`)),
    };
  });
}

function parseProvider(value: unknown, index: number) {
  const path = `providers[${index}]`;
  const record = requireRecord(value, path);
  const efforts = record.efforts;
  if (!Array.isArray(efforts)) throw new Error(`${path}.efforts must be an array`);
  const authMethods = record.authMethods;
  return {
    id: requireString(record.id, `${path}.id`),
    label: requireString(record.label, `${path}.label`),
    provider: requireString(record.provider, `${path}.provider`),
    model: requireString(record.model, `${path}.model`),
    active: requireBoolean(record.active, `${path}.active`),
    efforts: efforts.map((effort, effortIndex) =>
      requireString(effort, `${path}.efforts[${effortIndex}]`)),
    oauth: requireBoolean(record.oauth, `${path}.oauth`),
    ...(authMethods === undefined
      ? {}
      : {
          authMethods: Array.isArray(authMethods)
            ? authMethods.map((method, methodIndex) =>
                requireString(method, `${path}.authMethods[${methodIndex}]`))
            : (() => {
                throw new Error(`${path}.authMethods must be an array`);
              })(),
        }),
  };
}

function parseCommandList(raw: string): readonly CommandDescriptor[] {
  const value: unknown = JSON.parse(raw);
  if (!Array.isArray(value)) throw new Error("command list response must be an array");
  return value.map((entry, index) => {
    const path = `commands[${index}]`;
    const record = requireRecord(entry, path);
    const params = record.params;
    const aliases = record.aliases;
    if (!Array.isArray(params)) throw new Error(`${path}.params must be an array`);
    if (!Array.isArray(aliases)) throw new Error(`${path}.aliases must be an array`);
    return {
      id: requireString(record.id, `${path}.id`),
      label: requireString(record.label, `${path}.label`),
      description: requireString(record.description, `${path}.description`),
      category: requireString(record.category, `${path}.category`),
      ctype: requireString(record.ctype, `${path}.ctype`),
      params: params.map((param, paramIndex) => parseParameter(param, `${path}.params[${paramIndex}]`)),
      aliases: aliases.map((alias, aliasIndex) =>
        requireString(alias, `${path}.aliases[${aliasIndex}]`)),
      visible: requireBoolean(record.visible, `${path}.visible`),
      ...(record.shortcut === undefined
        ? {}
        : { shortcut: requireString(record.shortcut, `${path}.shortcut`) }),
    };
  });
}

function parseParameter(value: unknown, path: string) {
  const record = requireRecord(value, path);
  const result = {
    name: requireString(record.name, `${path}.name`),
    label: requireString(record.label, `${path}.label`),
    description: requireString(record.description, `${path}.description`),
    ptype: requireString(record.ptype, `${path}.ptype`),
    required: requireBoolean(record.required, `${path}.required`),
    positional: requireBoolean(record.positional, `${path}.positional`),
  } as {
    name: string;
    label: string;
    description: string;
    ptype: string;
    required: boolean;
    positional: boolean;
    default?: unknown;
    choices?: readonly string[];
  };
  if (record.default !== undefined) result.default = record.default;
  if (record.choices !== undefined) {
    if (!Array.isArray(record.choices)) throw new Error(`${path}.choices must be an array`);
    result.choices = record.choices.map((choice, index) =>
      requireString(choice, `${path}.choices[${index}]`));
  }
  return result;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireRecord(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  return value;
}

function requireString(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function requireBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${path} must be a boolean`);
  return value;
}
