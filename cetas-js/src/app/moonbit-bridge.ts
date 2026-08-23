import * as moonbit from "../../../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";
import type {
  AgentCallbacks,
  CetasAgentBridge,
  CetasHostConfig,
  CancellationToken,
  CommandDescriptor,
  ProviderAuthCapability,
  ProviderSetupSnapshot,
} from "./types.ts";

type RawConfigConstructor = new (
  cwd: string,
  maxToolRounds: number,
  home: string,
  permissionMode: string,
) => unknown;
type RawRuntimeConstructor = new (config: unknown) => unknown;

type RawRuntimeCreateAgent = (
  runtime: unknown,
  observerCallback: (eventJson: string) => void,
  renderCallback: (eventJson: string) => void,
  requestCallback: (eventJson: string) => Promise<string>,
  cancelCheck: () => boolean,
) => Promise<unknown>;

type RawRuntimeDescribeSetup = (runtime: unknown) => Promise<string>;
type RawRuntimeRefreshModelCatalogs = (runtime: unknown, providerIdsJson: string) => Promise<string>;
type RawRuntimeLoginProvider = (
  runtime: unknown,
  provider: string,
  observerCallback: (eventJson: string) => void,
  requestCallback: (eventJson: string) => Promise<string>,
  cancelCheck: () => boolean,
  method: string,
) => Promise<string>;
type RawRunTurn = (agent: unknown, prompt: string, sessionId: string) => Promise<string>;
type RawAbortTurn = (agent: unknown) => string;
type RawShutdown = (agent: unknown) => Promise<void>;
type RawListCommands = (agent: unknown) => string;
type RawInvokeCommand = (agent: unknown, id: string, argsJson: string) => Promise<string>;

const RawConfig = moonbit.CetasJsConfig as unknown as RawConfigConstructor;
const RawRuntime = (moonbit as unknown as {
  CetasJsRuntime: RawRuntimeConstructor;
}).CetasJsRuntime;
const rawRuntimeCreateAgent = (moonbit as unknown as {
  cetas_js_runtime_create_agent: RawRuntimeCreateAgent;
}).cetas_js_runtime_create_agent;
const rawRuntimeDescribeSetup = (moonbit as unknown as {
  cetas_js_runtime_describe_setup: RawRuntimeDescribeSetup;
}).cetas_js_runtime_describe_setup;
const rawRuntimeRefreshModelCatalogs = (moonbit as unknown as {
  cetas_js_runtime_refresh_model_catalogs: RawRuntimeRefreshModelCatalogs;
}).cetas_js_runtime_refresh_model_catalogs;
const rawRuntimeLoginProvider = (moonbit as unknown as {
  cetas_js_runtime_login_provider: RawRuntimeLoginProvider;
}).cetas_js_runtime_login_provider;
const rawRunTurn = moonbit.cetas_js_run_turn as unknown as RawRunTurn;
const rawAbortTurn = moonbit.cetas_js_abort_turn as unknown as RawAbortTurn;
const rawShutdown = moonbit.cetas_js_shutdown as unknown as RawShutdown;
const rawListCommands = moonbit.cetas_js_list_commands as unknown as RawListCommands;
const rawInvokeCommand = moonbit.cetas_js_invoke_command as unknown as RawInvokeCommand;

/**
 * Adapter for the generated MoonBit boundary. Provider settings and
 * credentials remain behind the MoonBit/provider extension seam; this TS
 * layer only carries capability snapshots and command JSON.
 */
export class MoonbitCetasAgentBridge implements CetasAgentBridge {
  private readonly configValue: unknown;
  private readonly runtimeValue: unknown;

  constructor(config: CetasHostConfig) {
    this.configValue = new RawConfig(
      config.cwd,
      config.maxToolRounds,
      config.home,
      config.permissionMode ?? "workspace_write",
    );
    this.runtimeValue = new RawRuntime(this.configValue);
  }

  async describeSetup(_config: CetasHostConfig): Promise<ProviderSetupSnapshot> {
    const raw = await rawRuntimeDescribeSetup(this.runtimeValue);
    return parseProviderSetup(raw);
  }

  async refreshModelCatalogs(
    _config: CetasHostConfig,
    providers?: readonly string[],
  ): Promise<ProviderSetupSnapshot> {
    const providerIdsJson = providers === undefined ? "" : JSON.stringify([...providers]);
    const raw = await rawRuntimeRefreshModelCatalogs(this.runtimeValue, providerIdsJson);
    return parseProviderSetup(raw);
  }

  createAgent(
    _config: CetasHostConfig,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
  ): Promise<unknown> {
    return rawRuntimeCreateAgent(
      this.runtimeValue,
      callbacks.observerCallback,
      callbacks.renderCallback,
      callbacks.requestCallback,
      () => cancellation?.isCancelled() ?? false,
    );
  }

  login(
    _config: CetasHostConfig,
    provider: string,
    callbacks: AgentCallbacks,
    cancellation?: CancellationToken,
    method?: string,
  ): Promise<string> {
    return rawRuntimeLoginProvider(
      this.runtimeValue,
      provider,
      callbacks.observerCallback,
      callbacks.requestCallback,
      () => cancellation?.isCancelled() ?? false,
      method ?? "",
    );
  }

  runTurn(agent: unknown, prompt: string, sessionId: string): Promise<string> {
    return rawRunTurn(agent, prompt, sessionId);
  }

  abortTurn(agent: unknown): string {
    return rawAbortTurn(agent);
  }

  shutdown(agent: unknown): Promise<void> {
    return rawShutdown(agent);
  }

  listCommands(agent: unknown): readonly CommandDescriptor[] {
    return parseCommandList(rawListCommands(agent));
  }

  invokeCommand(agent: unknown, id: string, argsJson: string): Promise<string> {
    return rawInvokeCommand(agent, id, argsJson);
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
