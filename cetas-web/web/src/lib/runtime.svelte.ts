import { addWorkspace, fetchTrace, fetchTranscript, listExts, listSessions, listWorkspaces, listModels, probeHealth, probeRuntime, switchSession as apiSwitchSession, type ExtInfo, type Health, type ModelCatalog, type RuntimeSnapshot, type SessionSummary, type WorkspaceInfo } from "./api";
import { createRealtimeClient, type RealtimeClient, type RealtimeState, type ServerEvent } from "./socket";
import type { TranscriptItem } from "./transcript";
import { createSmoothMarkdownStream } from "markstream-core";

export type ConnectionState = "checking" | "online" | "offline";
export type CoreState = "checking" | "ready" | "needs_setup" | "offline";

/** Paced reveal for one streaming turn; lives outside the items array. */
class LiveReveal {
  visible = $state("");
  done = $state(true);
  final = $state(true);
  #controller = createSmoothMarkdownStream({
    minCharsPerSecond: 30,
    maxCharsPerSecond: 2400,
    maxCommitFps: 30,
  });
  #unsubscribe: () => void;

  constructor() {
    this.#unsubscribe = this.#controller.subscribe(() => this.#sync());
    this.#sync();
  }

  #sync() {
    const snapshot = this.#controller.getSnapshot();
    this.visible = snapshot.visible;
    this.done = snapshot.done;
    this.final = snapshot.final;
  }

  enqueue(chunk: string) {
    this.#controller.enqueue(chunk);
  }

  finish() {
    this.#controller.finish();
  }

  reset() {
    this.#controller.reset();
  }
}

/** Transcript + live-turn state for one session. */
export class SessionState {
  id = $state("");
  items = $state<TranscriptItem[]>([]);
  busy = $state(false);
  model = $state("");
  effort = $state("");
  permission = $state("");
  cwd = $state("");
  liveTurnId = $state("");
  /** Prompts queued while a turn runs; dispatched in order on completion. */
  queue = $state<string[]>([]);
  /** Wall-clock per turn, from hub-stamped event ts (ms epoch). */
  turnTimes = $state<Record<string, { sentAt?: number; completedAt?: number }>>(
    {},
  );
  usage = $state({ input: 0, output: 0, total: 0, cached: 0, requests: 0 });
  /** Composer-dock stats (dsh StatsPills shape), recomputed from the
   * server's per-turn ledgers so reloads cannot lose them. */
  dockStats = $state<{
    turns: number;
    steps: number;
    ttftMs: number;
    tokPerSec: number;
    tokens: number;
    cacheHitPct: number | null;
  } | null>(null);
  context = $state<{
    measured: number | null;
    window: number | null;
    threshold: number;
    messages: number;
  } | null>(null);
  /** Ext ids active in the latest traced turn (drives the float window). */
  activeExts = $state<Set<string> | null>(null);
  /** Statusbar segments from the hub (key=value pairs rendered under the
   * input box) — the posoco-ext-statusbar aggregation. */
  statusSegments = $state<{ key: string; value: string; color: string | null }[]>([]);
  /** Quota readings pulled live from the active provider (windows with
   * used-percent, or balance amounts — shaped by the pushed data). */
  quota = $state<{
    provider: string;
    readings: QuotaReading[];
  } | null>(null);
  /** Every provider with a registered quota source — powers the expanded
   * multi-provider view of the status window. */
  quotaAll = $state<ProviderQuota[]>([]);
  /** Pending UiPort request awaiting a browser decision. */
  uiRequest = $state<{
    requestId: string;
    kind: "input" | "confirm" | "select";
    prompt: string;
    options: string[];
    defaultIndex: number | null;
    defaultText: string | null;
  } | null>(null);
  /** Not reactive itself; LiveReveal's own fields drive the view. */
  live: LiveReveal | null = null;
  replaySeq = 0;
  #pendingReasoning = "";
  #reasoningScheduled = false;

  constructor(id: string) {
    this.id = id;
  }

  ensureLive(): LiveReveal {
    this.live ??= new LiveReveal();
    return this.live;
  }

  enqueueReasoning(turnId: string, delta: string) {
    this.#pendingReasoning += delta;
    if (this.#reasoningScheduled) return;
    this.#reasoningScheduled = true;
    requestAnimationFrame(() => {
      this.#reasoningScheduled = false;
      this.#flushReasoning(turnId);
    });
  }

  #flushReasoning(turnId: string) {
    const delta = this.#pendingReasoning;
    this.#pendingReasoning = "";
    if (!delta) return;
    const index = this.items.findIndex(
      (item) => item.kind === "reasoning" && item.turnId === turnId,
    );
    if (index < 0) {
      // If the answer already started (rAF coalescing can let a text delta
      // win the race), the reasoning block is born collapsed.
      const hasAnswer = this.items.some(
        (item) => item.kind === "assistant" && item.turnId === turnId,
      );
      this.items = [
        ...this.items,
        { kind: "reasoning", turnId, text: delta, streaming: !hasAnswer },
      ];
      return;
    }
    const item = this.items[index];
    if (item.kind === "reasoning") {
      this.items[index] = { ...item, text: item.text + delta };
    }
  }
}

export type QuotaReading = {
  window: string;
  used_percent: number | null;
  amount: { value: string; currency: string } | null;
  available: boolean | null;
  fetched_at_ms: number | null;
};

export type ProviderQuota = { provider: string; readings: QuotaReading[] };

class RuntimeStore {
  http = $state<ConnectionState>("checking");
  socketState = $state<RealtimeState>("connecting");
  health = $state<Health | null>(null);
  core: CoreState = $derived.by(() => {
    const workspace = this.workspaces.find(
      (workspace) => workspace.cwd === this.activeWorkspace,
    );
    return workspace
      ? "ready"
      : this.http === "offline"
        ? "offline"
        : "checking";
  });

  workspaces = $state<WorkspaceInfo[]>([]);
  activeWorkspace = $state("");
  activeSessionId = $state("");
  catalog = $state<ModelCatalog | null>(null);

  sessionsByWorkspace = $state<Record<string, SessionSummary[]>>({});
  /** Locally-opened tabs per workspace; live turns span sessions. */
  openTabs = $state<Record<string, string[]>>({});

  #sessionStates = new Map<string, SessionState>();
  realtime: RealtimeClient;
  #lastSeq = 0;

  constructor() {
    this.realtime = createRealtimeClient((state) => {
      this.socketState = state;
    });
    this.realtime.onEvent((event) => this.#onEvent(event));
    void this.refresh();
  }

  session(id: string): SessionState | undefined {
    return this.#sessionStates.get(id);
  }

  ensureSession(id: string): SessionState {
    let state = this.#sessionStates.get(id);
    if (!state) {
      state = new SessionState(id);
      this.#sessionStates.set(id, state);
    }
    return state;
  }

  /** Reactive view helper: the active session's transcript state. */
  activeSession(): SessionState | undefined {
    return this.session(this.activeSessionId);
  }

  openTabsForActive(): string[] {
    return this.openTabs[this.activeWorkspace] ?? [];
  }

  openSession(id: string) {
    const current = this.openTabsForActive();
    if (!current.includes(id)) {
      this.openTabs[this.activeWorkspace] = [...current, id];
    }
  }

  closeTab(id: string) {
    const current = this.openTabsForActive();
    const next = current.filter((tab) => tab !== id);
    this.openTabs[this.activeWorkspace] = next;
    if (this.activeSessionId === id) {
      const fallback = next[next.length - 1];
      if (fallback) void this.switchSession(fallback);
    }
  }

  async refresh() {
    this.http = "checking";
    try {
      this.health = await probeHealth();
      this.http = "online";
    } catch {
      this.http = "offline";
    }
    try {
      const workspaces = await listWorkspaces();
      this.workspaces = workspaces.workspaces;
      this.activeWorkspace = workspaces.active;
    } catch {
      // Workspace surface is unavailable until the API is reachable.
    }
    try {
      const snapshot = await probeRuntime();
      this.#applySnapshot(snapshot);
    } catch {
      // A failed probe keeps the connection state visible.
    }
    await this.loadSessions();
    if (this.activeSessionId) {
      await Promise.all([
        this.replay(this.activeSessionId),
        this.loadCatalog(),
        this.loadExts(),
        this.refreshActiveExts(this.activeSessionId),
      ]);
      this.openSession(this.activeSessionId);
    }
  }

  #applySnapshot(snapshot: RuntimeSnapshot) {
    if (!snapshot.session_id) return;
    const state = this.ensureSession(snapshot.session_id);
    state.model = snapshot.model;
    state.effort = snapshot.effort;
    state.permission = snapshot.permission;
    state.cwd = snapshot.cwd;
    if (
      !this.activeSessionId ||
      this.workspaces.find((w) => w.cwd === snapshot.cwd)?.active
    ) {
      this.activeWorkspace = snapshot.cwd;
      this.activeSessionId = snapshot.session_id;
    }
  }

  async loadSessions() {
    try {
      const list = await listSessions();
      this.sessionsByWorkspace[list.cwd] = list.sessions;
    } catch {
      // Keep the last known list while the API is unreachable.
    }
  }

  exts = $state<ExtInfo[] | null>(null);

  async loadExts() {
    try {
      const zoo = await listExts();
      this.exts = zoo.extensions;
    } catch {
      // The float window simply stays idle without the zoo.
    }
  }

  /** Map trace signals of a session onto the exts that did the work, and
   * recompute cumulative usage/context from the server's turn ledgers (the
   * authoritative source — in-memory counters die on reload). */
  async refreshActiveExts(sessionId: string) {
    try {
      const page = await fetchTrace({ session: sessionId, limit: 400 });
      const active = new Set<string>();
      const num = (event: Record<string, unknown>, key: string) =>
        typeof event[key] === "number" ? (event[key] as number) : 0;
      const eventTs = (
        events: { type: string; ts?: number }[],
        type: string,
      ): number | null => {
        for (const event of events) {
          if (event.type === type && typeof event.ts === "number") {
            return event.ts;
          }
        }
        return null;
      };
      const usage = { input: 0, output: 0, total: 0, cached: 0, requests: 0 };
      let context: SessionState["context"] = null;
      // Composer-dock stats folded from the ledgers (dsh StatsPills shape):
      // turns/steps counts, mean TTFT, decode speed, token totals.
      let turns = 0;
      let steps = 0;
      let ttftTotal = 0;
      let ttftRounds = 0;
      let decodeMs = 0;
      let decodeTokens = 0;
      let tokens = 0;
      let cachedIn = 0;
      for (const turn of [...page.turns].reverse()) {
        const startedTs = eventTs(turn.events, "turn.started");
        const firstDeltaTs = eventTs(turn.events, "assistant.text_delta");
        if (firstDeltaTs !== null && startedTs !== null) {
          ttftTotal += firstDeltaTs - startedTs;
          ttftRounds += 1;
        }
        const completedTs = eventTs(turn.events, "turn.completed");
        if (firstDeltaTs !== null && completedTs !== null) {
          decodeMs += completedTs - firstDeltaTs;
        }
        for (const event of turn.events) {
          if (event.type === "tool.started") steps += 1;
          if (event.type === "turn.completed") turns += 1;
          if (event.type === "usage.delta") {
            decodeTokens += num(event, "output_tokens");
            tokens += num(event, "total_tokens");
            cachedIn += num(event, "cached_input_tokens");
          }
        }
      }
      const tokPerSec = decodeMs > 0 ? decodeTokens / (decodeMs / 1000) : 0;
      const dock = turns > 0 ? {
        turns,
        steps,
        ttftMs: ttftRounds > 0 ? Math.round(ttftTotal / ttftRounds) : 0,
        tokPerSec: Math.round(tokPerSec * 10) / 10,
        tokens,
        cacheHitPct: usage.input > 0 ? Math.round((cachedIn / usage.input) * 100) : null,
      } : null;
      for (const turn of [...page.turns].reverse()) {
        for (const event of turn.events) {
          if (event.type === "usage.delta") {
            const num = (key: string) =>
              typeof event[key] === "number" ? (event[key] as number) : 0;
            usage.input += num("input_tokens");
            usage.output += num("output_tokens");
            usage.total += num("total_tokens");
            usage.cached += num("cached_input_tokens");
            usage.requests += 1;
          } else if (event.type === "context.state") {
            context = {
              measured:
                typeof event.measured_tokens === "number"
                  ? event.measured_tokens
                  : null,
              window:
                typeof event.window_tokens === "number"
                  ? event.window_tokens
                  : null,
              threshold:
                typeof event.compact_threshold === "number"
                  ? event.compact_threshold
                  : 0.88,
              messages:
                typeof event.reading_message_count === "number"
                  ? event.reading_message_count
                  : 0,
            };
          }
        }
      }
      const exts = this.exts ?? [];
      const providerOf = (toolName: string): string | null => {
        for (const ext of exts) {
          for (const role of ext.roles) {
            if (role.role === "tools") {
              if (role.items.some((item) => item.label === toolName)) {
                return ext.id;
              }
            }
          }
        }
        return null;
      };
      for (const turn of page.turns) {
        for (const event of turn.events) {
          switch (event.type) {
            case "tool.started":
            case "tool.completed":
            case "tool.approved":
              if (typeof event.tool_name === "string") {
                const owner = providerOf(event.tool_name);
                if (owner) active.add(owner);
              }
              break;
            case "ui.request":
              active.add("cetas-web_ui");
              active.add("posoco_ext_permission");
              break;
            case "usage.delta":
            case "turn.accepted":
            case "turn.started":
            case "turn.completed":
            case "turn.failed":
            case "assistant.text_delta":
            case "assistant.reasoning_delta":
              active.add("posoco_ext_llm");
              break;
            case "session.snapshot":
            case "session.redirect":
              active.add("posoco_ext_fs_session");
              break;
            default:
              break;
          }
        }
      }
      const state = this.session(sessionId);
      if (state) {
        state.activeExts = active;
        if (usage.requests > 0) state.usage = usage;
        if (context) state.context = context;
        if (dock) state.dockStats = dock;
      }
    } catch {
      // Keep the previous indicators while the trace is unreachable.
    }
  }

  refreshQuota(sessionId?: string) {
    const target = sessionId ?? this.activeSessionId;
    if (target) {
      this.realtime.send({ type: "status.refresh", session_id: target });
    }
  }

  async loadCatalog() {
    try {
      this.catalog = await listModels();
    } catch {
      // The picker falls back to the current runtime values.
    }
  }

  #onEvent(event: ServerEvent) {
    if (typeof event.seq === "number") {
      if (event.seq <= this.#lastSeq) return;
      this.#lastSeq = event.seq;
    }
    const sessionId =
      typeof event.session_id === "string" && event.session_id.length > 0
        ? event.session_id
        : this.activeSessionId;

    switch (event.type) {
      case "session.snapshot": {
        if (
          typeof event.model !== "string" ||
          typeof event.effort !== "string" ||
          typeof event.cwd !== "string"
        )
          return;
        const state = this.ensureSession(sessionId);
        state.model = event.model;
        state.effort = event.effort;
        state.cwd = event.cwd;
        state.permission =
          typeof event.permission === "string" ? event.permission : "";
        state.busy = Boolean(event.busy);
        return;
      }

      case "turn.accepted": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        const turnId = typeof event.turn_id === "string" ? event.turn_id : "";
        state.busy = true;
        state.liveTurnId = turnId;
        state.turnTimes[turnId] = {
          sentAt: typeof event.ts === "number" ? event.ts : undefined,
        };
        state.ensureLive().reset();
        state.items = [
          ...state.items,
          {
            kind: "user",
            turnId,
            text: typeof event.prompt === "string" ? event.prompt : "",
          },
        ];
        return;
      }

      case "assistant.text_delta": {
        if (!sessionId || typeof event.delta !== "string") return;
        const state = this.ensureSession(sessionId);
        const turnId = typeof event.turn_id === "string" ? event.turn_id : "";
        // The answer item is created on first text so any reasoning item of
        // the same turn keeps its chronological place above it; the reasoning
        // block auto-collapses at that moment (streaming -> done).
        if (
          !state.items.some(
            (item) => item.kind === "assistant" && item.turnId === turnId,
          )
        ) {
          state.items = [
            ...state.items,
            { kind: "assistant", turnId, text: "", streaming: true },
          ];
          state.items = state.items.map((item) =>
            item.kind === "reasoning" && item.turnId === turnId
              ? { ...item, streaming: false }
              : item,
          );
        }
        state.ensureLive().enqueue(event.delta);
        return;
      }

      case "assistant.reasoning_delta": {
        if (!sessionId || typeof event.delta !== "string") return;
        const turnId = typeof event.turn_id === "string" ? event.turn_id : "";
        this.ensureSession(sessionId).enqueueReasoning(turnId, event.delta);
        return;
      }

      case "tool.started": {
        if (!sessionId || typeof event.tool_call_id !== "string") return;
        const state = this.ensureSession(sessionId);
        state.items = [
          ...state.items,
          {
            kind: "tool",
            turnId: typeof event.turn_id === "string" ? event.turn_id : "",
            callId: event.tool_call_id,
            name: typeof event.tool_name === "string" ? event.tool_name : "",
            status: "running",
            args:
              event.arguments !== undefined &&
              typeof event.arguments === "object" &&
              event.arguments !== null
                ? (event.arguments as Record<string, unknown>)
                : {},
            result: "",
          },
        ];
        return;
      }

      case "tool.completed": {
        if (!sessionId || typeof event.tool_call_id !== "string") return;
        const state = this.ensureSession(sessionId);
        state.items = state.items.map((item) =>
          item.kind === "tool" && item.callId === event.tool_call_id
            ? {
                ...item,
                status: event.is_error ? ("error" as const) : ("done" as const),
                result:
                  typeof event.result === "string" ? event.result : item.result,
              }
            : item,
        );
        return;
      }

      case "turn.completed":
      case "turn.failed": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        const turnId = typeof event.turn_id === "string" ? event.turn_id : "";
        state.busy = false;
        if (turnId) {
          const times = state.turnTimes[turnId] ?? {};
          times.completedAt =
            typeof event.ts === "number" ? event.ts : Date.now();
          state.turnTimes[turnId] = times;
        }
        if (state.liveTurnId === turnId && state.live) {
          state.live.finish();
          state.liveTurnId = "";
        }
        if (event.type === "turn.completed") {
          state.items = state.items.map((item) =>
            item.kind === "assistant" && item.turnId === turnId
              ? {
                  ...item,
                  text:
                    item.text ||
                    (typeof event.text === "string" ? event.text : ""),
                  streaming: false,
                }
              : item,
          );
        } else {
          state.items = [
            ...state.items.map((item) =>
              item.kind === "assistant" && item.turnId === turnId
                ? { ...item, streaming: false }
                : item,
            ),
            {
              kind: "error",
              turnId,
              text:
                typeof event.message === "string"
                  ? event.message
                  : "Turn failed",
            },
          ];
        }
        this.#dispatchQueue(sessionId);
        return;
      }

      case "usage.delta": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        const num = (key: string) =>
          typeof event[key] === "number" ? (event[key] as number) : 0;
        state.usage = {
          input: state.usage.input + num("input_tokens"),
          output: state.usage.output + num("output_tokens"),
          total: state.usage.total + num("total_tokens"),
          cached: state.usage.cached + num("cached_input_tokens"),
          requests: state.usage.requests + 1,
        };
        return;
      }

      case "context.state": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        state.context = {
          measured:
            typeof event.measured_tokens === "number"
              ? event.measured_tokens
              : null,
          window:
            typeof event.window_tokens === "number"
              ? event.window_tokens
              : null,
          threshold:
            typeof event.compact_threshold === "number"
              ? event.compact_threshold
              : 0.88,
          messages:
            typeof event.reading_message_count === "number"
              ? event.reading_message_count
              : 0,
        };
        return;
      }

      case "ui.request": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        const kind =
          typeof event.kind === "string"
            ? (event.kind as "input" | "confirm" | "select")
            : "select";
        const options =
          Array.isArray(event.options) &&
          event.options.every((option) => typeof option === "string")
            ? (event.options as string[])
            : [];
        state.uiRequest = {
          requestId:
            typeof event.request_id === "string" ? event.request_id : "",
          kind,
          prompt: typeof event.prompt === "string" ? event.prompt : "",
          options,
          defaultIndex:
            typeof event.default === "number" ? event.default : null,
          defaultText:
            typeof event.default === "string" ? event.default : null,
        };
        return;
      }

      case "ui.render": {
        if (
          !sessionId ||
          event.key !== "statusbar" ||
          !Array.isArray(event.entries)
        )
          return;
        const state = this.ensureSession(sessionId);
        state.statusSegments = event.entries
          .filter(
            (entry): entry is { key: string; value: string; color?: string } =>
              typeof entry === "object" &&
              entry !== null &&
              typeof (entry as { key?: unknown }).key === "string" &&
              typeof (entry as { value?: unknown }).value === "string",
          )
          .map((entry) => ({
            key: entry.key,
            value: entry.value as string,
            color: typeof entry.color === "string" ? entry.color : null,
          }));
        return;
      }

      case "statusbar.quota": {
        if (!this.activeSessionId) return;
        const payload = event.payload as
          | { provider?: string; readings?: QuotaReading[] }
          | undefined;
        if (!payload || !Array.isArray(payload.readings)) return;
        const state = this.ensureSession(this.activeSessionId);
        state.quota = {
          provider: payload.provider ?? "",
          readings: payload.readings,
        };
        return;
      }

      case "statusbar.quota_all": {
        if (!this.activeSessionId) return;
        const payload = event.payload as
          | { providers?: ProviderQuota[] }
          | undefined;
        if (!payload || !Array.isArray(payload.providers)) return;
        const state = this.ensureSession(this.activeSessionId);
        state.quotaAll = payload.providers;
        return;
      }

      case "usage.delta": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        const num = (key: string) =>
          typeof event[key] === "number" ? (event[key] as number) : 0;
        state.usage = {
          input: state.usage.input + num("input_tokens"),
          output: state.usage.output + num("output_tokens"),
          total: state.usage.total + num("total_tokens"),
          cached: state.usage.cached + num("cached_input_tokens"),
          requests: state.usage.requests + 1,
        };
        return;
      }

      case "context.state": {
        if (!sessionId) return;
        const state = this.ensureSession(sessionId);
        state.context = {
          measured:
            typeof event.measured_tokens === "number"
              ? event.measured_tokens
              : null,
          window:
            typeof event.window_tokens === "number"
              ? event.window_tokens
              : null,
          threshold:
            typeof event.compact_threshold === "number"
              ? event.compact_threshold
              : 0.88,
          messages:
            typeof event.reading_message_count === "number"
              ? event.reading_message_count
              : 0,
        };
        return;
      }

      case "protocol.error": {
        if (!this.activeSessionId) return;
        const state = this.ensureSession(this.activeSessionId);
        state.items = [
          ...state.items,
          {
            kind: "error",
            turnId: "",
            text:
              typeof event.message === "string"
                ? event.message
                : "Protocol error",
          },
        ];
        return;
      }

      default:
        return;
    }
  }

  enqueuePrompt(sessionId: string, prompt: string) {
    const state = this.ensureSession(sessionId);
    state.queue = [...state.queue, prompt];
  }

  removeQueued(sessionId: string, index: number) {
    const state = this.ensureSession(sessionId);
    state.queue = state.queue.filter((_, i) => i !== index);
  }

  #dispatchQueue(sessionId: string) {
    const state = this.session(sessionId);
    if (!state || state.busy || state.queue.length === 0) return;
    const next = state.queue[0];
    state.queue = state.queue.slice(1);
    const sent = this.realtime.send({
      type: "turn.start",
      prompt: next,
      session_id: sessionId,
    });
    if (!sent) state.queue = [next, ...state.queue];
  }

  respondUi(
    sessionId: string,
    requestId: string,
    response: Record<string, unknown>,
  ) {
    const state = this.session(sessionId);
    if (state && state.uiRequest?.requestId === requestId) {
      state.uiRequest = null;
    }
    this.realtime.send({ type: "ui.response", request_id: requestId, ...response });
  }

  async addOrSwitchWorkspace(cwd: string) {
    const list = await addWorkspace(cwd);
    this.workspaces = list.workspaces;
    this.activeWorkspace = list.active;
    await this.loadSessions();
    const info = this.workspaces.find((w) => w.cwd === list.active);
    if (info?.active_session) {
      await this.switchSession(info.active_session);
    }
  }

  async newSession() {
    const created = await apiSwitchSession();
    await this.switchSession(created.session_id);
  }

  async switchSession(id: string) {
    await apiSwitchSession(id);
    this.activeSessionId = id;
    this.openSession(id);
    await Promise.all([this.replay(id), this.loadCatalog(), this.loadSessions()]);
  }

  async replay(id: string) {
    const state = this.ensureSession(id);
    const seq = ++state.replaySeq;
    try {
      const replay = await fetchTranscript(id);
      if (seq === state.replaySeq) {
        state.items = replay.items;
        const raw = replay.context;
        if (raw && typeof raw === "object") {
          const record = raw as Record<string, unknown>;
          const num = (key: string): number | null =>
            typeof record[key] === "number" ? (record[key] as number) : null;
          state.context = {
            measured: num("last_measured_tokens"),
            window: num("window_tokens"),
            threshold:
              typeof record.compact_threshold === "number"
                ? record.compact_threshold
                : 0.88,
            messages:
              typeof record.reading_message_count === "number"
                ? record.reading_message_count
                : 0,
          };
        }
      }
    } catch {
      // Fresh sessions have no transcript; keep whatever is live.
    }
  }
}

export const runtimeStore = new RuntimeStore();

