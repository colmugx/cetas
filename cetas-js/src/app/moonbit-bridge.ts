import * as moonbit from "mbt:colmugx/cetas-js/lib";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { scanAndLoadPiPackages, type PiPackagesSummary } from "./pi-packages.ts";
import { decodeAgentRunTurnResult, AgentBusyError } from "./agent-busy.ts";
import { answerResponseJson, type QuestionAnswerResponse } from "../controllers/question-answer.ts";
import type { AgentRunTurnResultWire } from "./agent-busy.ts";
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
  cetas_js_cancel_pending_ratelimit(agent: moonbit.CetasJsAgent): void;
};

/** Non-blocking ask exports (see lib/question_bridge.mbt). */
const questionExports = moonbit as unknown as {
  cetas_js_answer_question(
    agent: moonbit.CetasJsAgent,
    questionId: string,
    responseJson: string,
  ): string;
  cetas_js_user_replied(agent: moonbit.CetasJsAgent): string;
};

/** Eager session-model restore export (see lib/session_model_restore.mbt). */
const sessionModelRestoreExports = moonbit as unknown as {
  cetas_js_restore_session_model(
    agent: moonbit.CetasJsAgent,
    sessionId: string,
  ): Promise<string>;
};

/**
 * Typed outcome of the Agent-level server compaction. `ok:false` carries a
 * machine-readable `errorKind` (`cancelled` | `auto_compact_failed` |
 * `error`) from the MoonBit envelope — never matched against detail text.
 */
export interface CompactSessionOutcome {
  ok: boolean;
  finalSessionId?: string;
  mode?: string;
  messagesAfter?: number;
  errorKind?: "cancelled" | "auto_compact_failed" | "error";
  detail?: string;
}

/**
 * Adapter for the generated MoonBit boundary. Provider settings and
 * credentials remain behind the MoonBit/provider extension seam; this TS
 * layer only carries capability snapshots and command JSON.
 */
export class MoonbitCetasAgentBridge implements CetasAgentBridge {
  private readonly configValue: moonbit.CetasJsConfig;
  private readonly runtimeValue: moonbit.CetasJsRuntime;
  private readonly goalSessionRoot: string;
  private readonly loadedPiEntries = new Set<string>();
  private toolCatalogValue: Readonly<Record<string, string>> = {};
  private piPackagesValue: PiPackagesSummary | undefined;

  constructor(config: CetasHostConfig) {
    this.goalSessionRoot = resolvedSessionsDir(config);
    this.configValue = new moonbit.CetasJsConfig(
      config.cwd,
      config.maxToolRounds,
      config.home,
      // Product default posture: yolo. A typo in an explicit value still
      // falls back to workspace_write on the MoonBit side (never widens).
      config.permissionMode ?? "yolo",
      // Empty string is the bridge's "not chosen" convention; the MoonBit
      // constructor then resolves the per-project session bucket.
      config.sessionsDir ?? "",
      // Same empty-string convention for the /help host note.
      config.hostHelpNote ?? "",
      // Same empty-string convention for the version/distribution line.
      config.versionNote ?? "",
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
   * Live `/models` catalog refresh (compose-first startup). Unlike
   * `refreshModelCatalogs` this never evicts a provider; the MoonBit side
   * updates its process/disk caches and hot-swaps the composed agent's
   * router before resolving the summary JSON
   * `{"results":[{"provider","status","slots"?,"reason"?}]}`. An empty
   * selector refreshes all refreshable providers. Aborting `signal`
   * cancels the refresh coroutine — the only rejection path.
   */
  refreshModelListsLive(
    _config: CetasHostConfig,
    providerIdsJson: string,
    signal?: AbortSignal,
  ): Promise<string> {
    // The MoonBit export takes the signal positionally; a fresh never-aborted
    // controller keeps signal-less callers (tests, smoke) on the same path.
    return moonbit.cetas_js_runtime_refresh_model_lists_live(
      this.runtimeValue,
      providerIdsJson,
      signal ?? new AbortController().signal,
    );
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

  connectMagpie(url: string, credential: string): Promise<string> {
    return moonbit.cetas_js_runtime_connect_magpie(this.runtimeValue, url, credential);
  }

  commitMagpieCredential(credential: string): Promise<void> {
    return moonbit.cetas_js_runtime_commit_magpie_credential(this.runtimeValue, credential);
  }

  finishMagpieCredential(rollback: boolean): Promise<void> {
    return moonbit.cetas_js_runtime_finish_magpie_credential(this.runtimeValue, rollback);
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
    // Structured Busy boundary: the host-facing shape stays Promise<string>,
    // but the wire is the dedicated `cetas_js_run_turn_result` envelope —
    // `kind` discriminates structurally, so a legitimate assistant JSON
    // transcript can never be misread as a lost core admission. A Busy
    // envelope surfaces as the typed AgentBusyError rejection that keeps the
    // incumbent operation identity; every non-Busy error still rejects.
    return this.runTurnResult(agent, prompt, sessionId, signal, images).then(
      (result) => {
        if (result.kind === "busy") {
          throw new AgentBusyError(result.operation_id, result.session);
        }
        return result.transcript;
      },
    );
  }

  /**
   * Dedicated run-turn boundary: resolves the structurally discriminated
   * envelope instead of mixing raw transcript bytes with a Busy marker. The
   * envelope is decoded exactly once here; callers never re-parse the
   * transcript body.
   */
  runTurnResult(
    agent: unknown,
    prompt: string,
    sessionId: string,
    signal?: AbortSignal,
    images?: readonly ImageAttachment[],
  ): Promise<AgentRunTurnResultWire> {
    // The MoonBit export takes the signal positionally; a fresh never-aborted
    // controller keeps signal-less callers (tests, smoke) on the same path.
    return moonbit
      .cetas_js_run_turn_result(
        agent as moonbit.CetasJsAgent,
        prompt,
        imagesJsonFor(images),
        sessionId,
        signal ?? new AbortController().signal,
      )
      .then(decodeAgentRunTurnResult);
  }

  private goalCheckpointPath(sessionId: string): string {
    const filename = createHash("sha256").update(sessionId, "utf8").digest("hex") + ".json";
    const directory = join(this.goalSessionRoot, "goals");
    return join(directory, filename);
  }

  private goalTranscriptDigest(sessionId: string): string {
    // Checkpoint restoration is safe only against the exact committed
    // transcript revision it was captured with. A changed/missing session
    // journal must not silently replay a stale goal.
    if (sessionId.length === 0 || sessionId.includes("/") ||
        sessionId.includes("\\") || sessionId === "." || sessionId === "..") {
      throw new Error("invalid goal session id");
    }
    const journal = join(this.goalSessionRoot, `${sessionId}.jsonl`);
    return createHash("sha256").update(readFileSync(journal)).digest("hex");
  }

  private persistGoalCheckpoint(agent: moonbit.CetasJsAgent, sessionId: string): void {
    const raw = moonbit.cetas_js_goal_checkpoint(agent);
    const checkpoint: unknown = JSON.parse(raw);
    const path = this.goalCheckpointPath(sessionId);
    if (isRecord(checkpoint) && checkpoint.ok === true &&
        isRecord(checkpoint.snapshot) && checkpoint.snapshot.session === sessionId) {
      const dir = join(path, "..");
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const temp = path + ".tmp";
      writeFileSync(temp, JSON.stringify({
        session: sessionId,
        transcriptDigest: this.goalTranscriptDigest(sessionId),
        checkpoint: checkpoint.snapshot,
      }), { mode: 0o600 });
      renameSync(temp, path);
    } else {
      rmSync(path, { force: true });
    }
  }

  async goalStart(agent: unknown, objective: string, sessionId: string, signal?: AbortSignal): Promise<string> {
    const raw = await moonbit.cetas_js_goal_start(agent as moonbit.CetasJsAgent, objective, sessionId, signal ?? new AbortController().signal);
    this.persistGoalCheckpoint(agent as moonbit.CetasJsAgent, sessionId);
    return raw;
  }

  async goalResume(agent: unknown, sessionId: string, signal?: AbortSignal): Promise<string> {
    const current: unknown = JSON.parse(moonbit.cetas_js_goal_status(agent as moonbit.CetasJsAgent));
    if (isRecord(current) && current.status === "Idle") {
      let snapshot: unknown;
      try {
        snapshot = JSON.parse(readFileSync(this.goalCheckpointPath(sessionId), "utf8"));
      } catch {
        return JSON.stringify({ type: "failure", reason: "no persisted goal for this session" });
      }
      if (!isRecord(snapshot) || snapshot.session !== sessionId ||
          typeof snapshot.transcriptDigest !== "string" ||
          !isRecord(snapshot.checkpoint)) {
        return JSON.stringify({ type: "failure", reason: "invalid goal checkpoint envelope" });
      }
      let digest: string;
      try {
        digest = this.goalTranscriptDigest(sessionId);
      } catch {
        return JSON.stringify({ type: "failure", reason: "goal transcript unavailable; restore refused" });
      }
      if (digest !== snapshot.transcriptDigest) {
        return JSON.stringify({ type: "failure", reason: "goal transcript changed since checkpoint; restore refused" });
      }
      const restored: unknown = JSON.parse(moonbit.cetas_js_goal_restore(
        agent as moonbit.CetasJsAgent, JSON.stringify(snapshot.checkpoint),
      ));
      if (!isRecord(restored) || restored.ok !== true) {
        return JSON.stringify({
          type: "failure",
          reason: isRecord(restored) && typeof restored.reason === "string"
            ? restored.reason : "goal checkpoint restore failed",
        });
      }
    }
    const raw = await moonbit.cetas_js_goal_resume(agent as moonbit.CetasJsAgent, sessionId, signal ?? new AbortController().signal);
    this.persistGoalCheckpoint(agent as moonbit.CetasJsAgent, sessionId);
    return raw;
  }

  goalPause(agent: unknown): void {
    moonbit.cetas_js_goal_pause(agent as moonbit.CetasJsAgent);
  }

  goalStatus(agent: unknown): string {
    return moonbit.cetas_js_goal_status(agent as moonbit.CetasJsAgent);
  }

  cancelPendingRateLimit(agent: unknown): void {
    rateLimitExports.cetas_js_cancel_pending_ratelimit(agent as moonbit.CetasJsAgent);
  }

  /**
   * Bind the core Wakeup admission window (the host's active session).
   * Synchronous: `undefined` clears, and an empty string never crosses the
   * FFI — the MoonBit export follows the bridge's empty-string convention.
   */
  setActiveSession(agent: unknown, sessionId?: string): void {
    moonbit.cetas_js_set_active_session(agent as moonbit.CetasJsAgent, sessionId ?? "");
  }

  /**
   * Eagerly apply the session's recorded model selection at a user-intent
   * session switch. The MoonBit export never rejects; `applied:false` covers
   * both "nothing recorded" and "already attempted for this session".
   */
  async restoreSessionModel(
    agent: unknown,
    sessionId: string,
  ): Promise<{ applied: boolean; already_restored: boolean }> {
    const raw = await sessionModelRestoreExports.cetas_js_restore_session_model(
      agent as moonbit.CetasJsAgent,
      sessionId,
    );
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) throw new Error("session model restore response must be an object");
    return {
      applied: value.applied === true,
      already_restored: value.already_restored === true,
    };
  }

  /** Interrupted-turn recovery through the Agent's resume_turn entry. */
  resumeTurn(
    agent: unknown,
    sessionId: string,
    signal?: AbortSignal,
  ): Promise<string> {
    return moonbit.cetas_js_resume_turn(
      agent as moonbit.CetasJsAgent,
      sessionId,
      signal ?? new AbortController().signal,
    );
  }

  activeModelSupportsImages(agent: unknown): boolean {
    return moonbit.cetas_js_active_model_supports_images(agent as moonbit.CetasJsAgent) === "true";
  }

  abortTurn(agent: unknown): string {
    return moonbit.cetas_js_abort_turn(agent as moonbit.CetasJsAgent);
  }

  /**
   * Agent-level server compaction on the long-lived handle (same Agent, no
   * recomposition). The MoonBit export never rejects; failures arrive as the
   * typed envelope, cancellations included.
   */
  async compactSession(
    agent: unknown,
    sessionId: string,
    signal?: AbortSignal,
  ): Promise<CompactSessionOutcome> {
    const raw = await moonbit.cetas_js_compact_session(
      agent as moonbit.CetasJsAgent,
      sessionId,
      signal ?? new AbortController().signal,
    );
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) throw new Error("compact response must be an object");
    if (value.ok === true) {
      return {
        ok: true,
        finalSessionId: requireString(value.final_session_id, "compact.final_session_id"),
        mode: requireString(value.mode, "compact.mode"),
        messagesAfter: requireNumber(value.messages_after, "compact.messages_after"),
      };
    }
    const kind = value.error_kind;
    if (kind !== "cancelled" && kind !== "auto_compact_failed" && kind !== "error") {
      throw new Error("compact response.error_kind is unsupported");
    }
    return {
      ok: false,
      errorKind: kind,
      detail: requireString(value.detail, "compact.detail"),
    };
  }

  enqueueFollowUp(
    agent: unknown,
    prompt: string,
    images?: readonly ImageAttachment[],
  ): string {
    return moonbit.cetas_js_enqueue_follow_up(agent as moonbit.CetasJsAgent, prompt, imagesJsonFor(images));
  }

  /**
   * The user sent a plain reply: close every parked non-blocking question.
   * The MoonBit export is infallible (display-state sync), so the count is
   * returned for diagnostics and never blocks admission.
   */
  closeUserQuestions(agent: unknown): number {
    const raw = questionExports.cetas_js_user_replied(agent as moonbit.CetasJsAgent);
    const verdict = JSON.parse(raw) as { closed?: unknown };
    return typeof verdict.closed === "number" ? verdict.closed : 0;
  }

  async answerQuestion(
    agent: unknown,
    questionId: string,
    response: QuestionAnswerResponse,
  ): Promise<boolean> {
    // Resolve only. The accepted answer rides the extension's next
    // `before_model` envelope; the caller separately submits the human's
    // echo as ordinary input so a turn (or a queued follow-up) carries it.
    const raw = questionExports.cetas_js_answer_question(
      agent as moonbit.CetasJsAgent,
      questionId,
      answerResponseJson(response),
    );
    const verdict = JSON.parse(raw) as { ok?: unknown };
    return verdict.ok === true;
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

  sessionTitles(sessionsDir: string): Promise<string> {
    return moonbit.cetas_js_session_titles(sessionsDir);
  }
}

/**
 * Resolved per-project sessions directory for a host config. The bucket
 * formula lives in posoco-ext-fs-session; TypeScript only asks for the
 * resolved path (never re-derives it). Mirrors the MoonBit config
 * constructor: an explicit `sessionsDir` wins, otherwise the per-project
 * bucket is resolved here.
 */
export function resolvedSessionsDir(config: CetasHostConfig): string {
  return config.sessionsDir ??
    moonbit.cetas_js_sessions_dir(config.home, config.cwd);
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

function requireString(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function requireNumber(value: unknown, path: string): number {
  if (typeof value !== "number") throw new Error(`${path} must be a number`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function requireRecord(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  return value;
}

function requireBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${path} must be a boolean`);
  return value;
}
