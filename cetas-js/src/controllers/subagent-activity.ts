/**
 * subagent-activity.ts — live per-child activity fold for embedded
 * subagents, keyed by the child session so both the parent `agent` tool row
 * (via `parent_call`) and the background header can render progress.
 *
 * Lifecycle model (two distinct clocks):
 * - Child turns: the child's own `turn_started`/`turn_completed` events.
 *   On a foreground run they end the run; on a background child they only
 *   record the child-turn outcome — background work may still be running.
 * - Background work: `background_spawned` (task accepted), then the
 *   declaration-only `background_exited` (actual exit, best-effort state
 *   word) and the authoritative `background_terminal` (final classification
 *   + summary, exactly once per run at the delivery point).
 *
 * Runs are identified by the `spawned` announcement's real parent call id
 * (`run_id`), refined by `task_id` once accepted. A `spawned` with a changed
 * call id opens a new run (resume); a repeated spawn of the same call is
 * idempotent. Finished runs are never revived by stale same-run events —
 * only an explicit new spawn or a genuinely new parent call reactivates.
 *
 * Each child gets a stable display nickname (apple, banana, …) allocated
 * once per store and kept across resumes. Records are tagged with the
 * owning parent session so shells can scope display and notifications.
 *
 * `apply()` returns whether the event actually changed state, so callers
 * can skip UI work for no-ops. Pure logic — no TUI state, no timers — so
 * it is unit-testable. The owning shell constructs its own store instance;
 * nothing here is process-global.
 */

import type { CetasEvent } from "../events.ts";

/** Tail-window caps: display-safety, not correctness. */
const TEXT_TAIL_CHARS = 400;
const ARG_PREVIEW_VALUE_CHARS = 60;
const ARG_PREVIEW_MAX_CHARS = 200;
/** Expanded-view step log cap (oldest entries drop first). */
const HISTORY_MAX = 12;
/** History line preview width. */
const HISTORY_TEXT_CHARS = 80;

/** Nickname word list, allocated in order; exhausted lists take `-N` suffixes. */
export const SUBAGENT_NAME_WORDS: readonly string[] = [
  "apple",
  "banana",
  "cherry",
  "durian",
  "fig",
  "grape",
  "honeydew",
  "kiwi",
  "lemon",
  "mango",
  "nectarine",
  "orange",
  "papaya",
  "plum",
  "quince",
  "raspberry",
  "strawberry",
  "tangerine",
  "watermelon",
];

/** Word list index → unique nickname (`apple`, …, `apple-2`, `banana-2`, …). */
export function subagentNickname(index: number): string {
  const word = SUBAGENT_NAME_WORDS[index % SUBAGENT_NAME_WORDS.length]!;
  const round = Math.floor(index / SUBAGENT_NAME_WORDS.length);
  return round === 0 ? word : `${word}-${round + 1}`;
}

/** Terminal state words the extension emits or classifies. */
const TERMINAL_SUCCESS = new Set(["completed", "succeeded", "success", "ok"]);
const TERMINAL_FAILURE = new Set([
  "failed",
  "error",
  "cancelled",
  "canceled",
  "timed_out",
  "timeout",
  "aborted",
]);

/**
 * Coarse display class of a raw terminal word. Unknown words map to
 * undefined — never guessed as failure — and are preserved verbatim in
 * `terminal_state` for display and notification.
 */
function coarseTerminal(word: string): "completed" | "failed" | undefined {
  if (TERMINAL_SUCCESS.has(word)) return "completed";
  if (TERMINAL_FAILURE.has(word)) return "failed";
  return undefined;
}

export interface SubagentActivity {
  readonly child_session: string;
  readonly kind: string;
  parent_call: string;
  /** Coarse display state; raw terminal words live in `terminal_state`. */
  status: "running" | "completed" | "failed";
  started_at: number;
  /** Count of child `turn_started` events seen this run. */
  steps: number
  /** Current in-flight child tool call, or undefined when idle. */
  current_tool?: string;
  last_tool?: string;
  /** Trailing window of the child's latest assistant text/reasoning. */
  text_tail: string;
  /** Bound model slot (from the `spawned` announcement). */
  model?: string;
  effort?: string;
  /** True when the child runs as a background task. */
  background?: boolean;
  /** Authoritative final summary (background delivery point). */
  summary?: string;
  /** Bounded recent-step log (oldest first): step starts + tool calls. */
  history: string[];
  /** Latest failure/diagnostic text (child turn or exit detail). */
  error?: string;
  /** Bumped on every mutation; renderers cache renders against this. */
  version: number;
  /** Stable UI nickname, allocated once and kept across resumes. */
  readonly display_name: string;
  /** Owning parent session tag, fixed at record creation. */
  readonly owner_session?: string;
  /**
   * Spawn identity of the current run: the real parent call id of the
   * `spawned` announcement ("" until one is seen).
   */
  run_id: string;
  /** Background task id (from `background_spawned`), per run. */
  task_id?: string;
  /** Stable first-appearance order for display sorting (per store). */
  readonly seq: number;
  /** Latest raw terminal word (best-effort exit, then authoritative). */
  terminal_state?: string;
  /** Authoritative `background_terminal` received for this run. */
  terminal_received: boolean;
  /** Terminal notification claimed for this run. */
  terminal_notified: boolean;
  /** Outcome of the last child turn this run. */
  child_turn_state?: "completed" | "failed";
  /** Actual exit observed (`background_exited`) — no longer running. */
  exited?: boolean;
  /** A core `background_outcome_ready` receipt arrived for this run's task. */
  outcome_ready?: boolean;
}

/** Snapshot handed to the shell for the one-shot terminal notification. */
export interface SubagentTerminalNotice {
  readonly child_session: string;
  readonly display_name: string;
  readonly kind: string;
  /** Raw authoritative word: completed / failed / cancelled / timed_out / … */
  readonly terminal_state: string;
  /** True only for a success-classified word. */
  readonly success: boolean;
  readonly summary?: string;
  readonly task_id?: string;
  readonly run_id: string;
  readonly owner_session?: string;
}

/** Write `value` only when it differs; reports whether the record changed. */
function put<K extends keyof SubagentActivity>(
  record: SubagentActivity,
  key: K,
  value: SubagentActivity[K],
): boolean {
  if (record[key] === value) return false;
  record[key] = value;
  return true;
}

function tail(text: string, max: number): string {
  return text.length <= max ? text : text.slice(text.length - max);
}

function oneLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Compact args preview: `key=value` pairs, per-value and total capped. */
export function argsPreview(args: unknown): string {
  if (typeof args !== "object" || args === null) return "";
  const parts: string[] = [];
  let total = 0;
  for (const [key, value] of Object.entries(args as Record<string, unknown>)) {
    let rendered: string;
    if (typeof value === "string") {
      rendered =
        value.length > ARG_PREVIEW_VALUE_CHARS
          ? `${value.slice(0, ARG_PREVIEW_VALUE_CHARS)}…`
          : value;
    } else if (typeof value === "number" || typeof value === "boolean") {
      rendered = String(value);
    } else {
      continue;
    }
    const part = `${key}=${oneLine(rendered)}`;
    if (total + part.length > ARG_PREVIEW_MAX_CHARS) break;
    parts.push(part);
    total += part.length + 2;
  }
  return oneLine(parts.join(", "));
}

/** Event types allowed to create a record when no `spawned` was seen. */
const CREATABLE_TYPES = new Set([
  "turn_started",
  "stream_chunk",
  "message_end",
  "tool_call_started",
  "tool_call_completed",
  "tool_call_deferred",
  "turn_completed",
  "turn_failed",
  "custom",
]);

export class SubagentActivityStore {
  private readonly records = new Map<string, SubagentActivity>();
  /** child_session → nickname; allocation is monotonic and never recycled. */
  private readonly names = new Map<string, string>();
  /**
   * Ready outcome receipts (task_id → owning session) not yet known to be
   * delivered. Delivery is the subagent run's authoritative
   * `background_terminal` — an exit alone never clears a receipt. The
   * "N results waiting" indicator counts these receipts, never wakeup
   * tickets: a merged ticket may carry several results, and a ticket being
   * executed does not mean every result has been injected.
   */
  private readonly readyReceipts = new Map<string, string | undefined>();
  private nameCounter = 0;
  private seqCounter = 0;
  private ownerSession: string | undefined;

  /** `now` is injectable so elapsed time and run starts are testable. */
  constructor(private readonly now: () => number = Date.now) {}

  /**
   * Scope for records created hereafter (the current parent session).
   * Existing records keep the owner they were created with.
   */
  setOwnerSession(session: string | undefined): void {
    this.ownerSession = session;
  }

  get(child_session: string): SubagentActivity | undefined {
    return this.records.get(child_session);
  }

  /** Most recent running activity for a parent tool call, if any. */
  runningForParentCall(parent_call: string): SubagentActivity | undefined {
    let latest: SubagentActivity | undefined;
    for (const record of this.records.values()) {
      if (record.parent_call === parent_call && this.isRunnable(record)) {
        latest ??= record;
      }
    }
    return latest;
  }

  /** Snapshot of every still-running activity, oldest spawn first. */
  running(ownerSession?: string): readonly SubagentActivity[] {
    return [...this.records.values()]
      .filter(
        (record) =>
          this.isRunnable(record) && this.inScope(record, ownerSession),
      )
      .sort((a, b) => a.started_at - b.started_at);
  }

  /**
   * Live background children in stable first-appearance order. A background
   * spawn only counts once accepted (task_id present), so refused spawns
   * never linger as phantom running work.
   */
  runningBackground(ownerSession?: string): readonly SubagentActivity[] {
    return [...this.records.values()]
      .filter(
        (record) =>
          record.background === true &&
          record.task_id !== undefined &&
          this.isRunnable(record) &&
          this.inScope(record, ownerSession),
      )
      .sort((a, b) => a.seq - b.seq);
  }

  all(ownerSession?: string): readonly SubagentActivity[] {
    return [...this.records.values()].filter((record) =>
      this.inScope(record, ownerSession),
    );
  }

  /**
   * Record a core `background_outcome_ready` receipt for one task. The
   * receipt is counted as waiting until the matching run's authoritative
   * terminal is folded; duplicates are no-ops. Returns whether it changed.
   */
  noteOutcomeReady(taskId: string, ownerSession?: string): boolean {
    if (taskId.length === 0 || this.readyReceipts.has(taskId)) return false;
    this.readyReceipts.set(taskId, ownerSession);
    const record = this.recordForTask(taskId);
    if (record !== undefined && record.outcome_ready !== true) {
      record.outcome_ready = true;
      record.version += 1;
    }
    return true;
  }

  /**
   * Ready-but-not-yet-delivered receipt count for a session. Receipts whose
   * run was never observed stay waiting (the store may have been cleared);
   * the authoritative terminal clears the matching receipt.
   */
  resultsWaiting(ownerSession?: string): number {
    let count = 0;
    for (const [taskId, owner] of this.readyReceipts) {
      if (ownerSession !== undefined && owner !== ownerSession) continue;
      const record = this.recordForTask(taskId);
      if (record !== undefined && record.terminal_received === true) continue;
      count += 1;
    }
    return count;
  }

  private recordForTask(taskId: string): SubagentActivity | undefined {
    for (const record of this.records.values()) {
      if (record.task_id === taskId) return record;
    }
    return undefined;
  }

  clear(): void {
    this.records.clear();
    this.names.clear();
    this.readyReceipts.clear();
    this.nameCounter = 0;
    this.seqCounter = 0;
  }

  /**
   * Hand out the first authoritative terminal of a run, exactly once.
   * Returns undefined when no authoritative terminal was received, when the
   * notification was already claimed for this run, or — with `ownerSession`
   * given — when the record belongs to another session (no cross-session
   * notification insertion). Resuming re-arms the notification.
   */
  claimTerminalNotification(
    child_session: string,
    ownerSession?: string,
  ): SubagentTerminalNotice | undefined {
    const record = this.records.get(child_session);
    if (record === undefined) return undefined;
    if (!this.inScope(record, ownerSession)) return undefined;
    if (!record.terminal_received || record.terminal_notified) return undefined;
    record.terminal_notified = true;
    record.version += 1;
    const state = record.terminal_state;
    return {
      child_session: record.child_session,
      display_name: record.display_name,
      kind: record.kind,
      terminal_state: state ?? "unknown",
      success: state !== undefined && coarseTerminal(state) === "completed",
      summary: record.summary,
      task_id: record.task_id,
      run_id: record.run_id,
      owner_session: record.owner_session,
    };
  }

  /**
   * Fold one parsed child event. Unwraps the `subagent_event` envelope;
   * returns whether the fold changed any state — non-subagent events,
   * no-op replays, and unrecognized labels all return false.
   */
  apply(event: CetasEvent, ownerSession?: string): boolean {
    if (event.type !== "subagent_event") return false;
    const existing = this.records.get(event.child_session);
    if (existing !== undefined) return this.fold(existing, event);
    if (!CREATABLE_TYPES.has(event.ev.type)) return false;
    const record = this.createRecord(event, ownerSession ?? this.ownerSession);
    return this.fold(record, event);
  }

  /** Lifecycle liveness: status running, no exit or authoritative terminal. */
  private isLive(record: SubagentActivity): boolean {
    return (
      record.status === "running" &&
      record.exited !== true &&
      record.terminal_received !== true
    );
  }

  /** Running-list eligibility (background children need their task id). */
  private isRunnable(record: SubagentActivity): boolean {
    return this.isLive(record) && !(record.background === true && record.task_id === undefined);
  }

  private inScope(record: SubagentActivity, ownerSession?: string): boolean {
    return ownerSession === undefined || record.owner_session === ownerSession;
  }

  /** Identity a new spawn/turn is compared against to detect a new run. */
  private runIdentity(record: SubagentActivity): string {
    if (record.run_id !== "") return record.run_id;
    return record.parent_call !== "background" ? record.parent_call : "";
  }

  /**
   * Start a fresh run on an existing record: keep identity (nickname, seq,
   * owner, kind, model/effort, bounded history), reset everything that
   * belongs to the previous run — including its notification state.
   */
  private beginRun(record: SubagentActivity, parentCall: string): void {
    record.status = "running";
    record.parent_call = parentCall;
    record.run_id = parentCall;
    record.started_at = this.now();
    record.steps = 0;
    record.current_tool = undefined;
    record.text_tail = "";
    record.error = undefined;
    record.summary = undefined;
    record.task_id = undefined;
    record.terminal_state = undefined;
    record.terminal_received = false;
    record.terminal_notified = false;
    record.child_turn_state = undefined;
    record.exited = false;
    record.version += 1;
  }

  private createRecord(
    event: CetasEvent & { type: "subagent_event" },
    ownerSession: string | undefined,
  ): SubagentActivity {
    const parentCall = event.parent_call;
    let display_name = this.names.get(event.child_session);
    if (display_name === undefined) {
      display_name = subagentNickname(this.nameCounter);
      this.nameCounter += 1;
      this.names.set(event.child_session, display_name);
    }
    const record: SubagentActivity = {
      child_session: event.child_session,
      kind: event.kind,
      parent_call: parentCall,
      status: "running",
      started_at: this.now(),
      steps: 0,
      text_tail: "",
      history: [],
      version: 0,
      display_name,
      owner_session: ownerSession,
      run_id: parentCall !== "background" ? parentCall : "",
      seq: this.seqCounter,
      terminal_received: false,
      terminal_notified: false,
    };
    this.seqCounter += 1;
    this.records.set(event.child_session, record);
    return record;
  }

  /** Fold one event into an existing record; true when state changed. */
  private fold(
    record: SubagentActivity,
    event: CetasEvent & { type: "subagent_event" },
  ): boolean {
    if (event.ev.type === "custom") {
      return this.applyCustom(record, event.ev, event.parent_call);
    }
    switch (event.ev.type) {
      case "turn_started": {
        const call = event.parent_call;
        const identity = this.runIdentity(record);
        const sameRun = call === "background" || call === identity;
        if (sameRun) {
          // Same run: count the step — but never revive a finished run.
          if (!this.isLive(record)) return false;
        } else if (identity === "" && this.isLive(record)) {
          // Compat path: the run's spawning call arrives late. Adopt it
          // without resetting the run already in progress.
          record.parent_call = call;
          record.run_id = call;
        } else {
          // A genuinely new parent call: explicit resume/reactivation.
          this.beginRun(record, call);
        }
        record.steps += 1;
        this.pushHistory(record, `▸ step ${record.steps}`);
        record.version += 1;
        return true;
      }
      case "stream_chunk": {
        if (put(record, "text_tail", tail(record.text_tail + event.ev.raw, TEXT_TAIL_CHARS))) {
          record.version += 1;
          return true;
        }
        return false;
      }
      case "message_end": {
        const blocks = event.ev.message.content;
        const lastText = [...blocks].reverse().find((block) => block.type === "text");
        if (
          lastText !== undefined &&
          lastText.type === "text" &&
          lastText.text.trim().length > 0
        ) {
          if (put(record, "text_tail", tail(lastText.text, TEXT_TAIL_CHARS))) {
            record.version += 1;
            return true;
          }
        }
        return false;
      }
      case "tool_call_started": {
        let changed = put(record, "current_tool", event.ev.tool_name);
        const preview = argsPreview(event.ev.args);
        if (preview.length > 0) {
          changed =
            put(
              record,
              "text_tail",
              tail(
                `${record.text_tail}\n${event.ev.tool_name} ${preview}`.slice(
                  -TEXT_TAIL_CHARS * 2,
                ),
                TEXT_TAIL_CHARS,
              ),
            ) || changed;
        }
        changed =
          this.pushHistory(
            record,
            preview.length > 0
              ? `▸ ${event.ev.tool_name} ${preview}`
              : `▸ ${event.ev.tool_name}`,
          ) || changed;
        if (changed) record.version += 1;
        return changed;
      }
      case "tool_call_completed": {
        let changed = put(record, "last_tool", record.current_tool ?? event.ev.tool_call_id);
        changed = put(record, "current_tool", undefined) || changed;
        if (changed) record.version += 1;
        return changed;
      }
      case "tool_call_deferred": {
        let changed = put(record, "last_tool", record.current_tool);
        changed = put(record, "current_tool", undefined) || changed;
        if (changed) record.version += 1;
        return changed;
      }
      case "turn_completed": {
        if (!this.isLive(record)) return false;
        let changed = put(record, "child_turn_state", "completed");
        changed = put(record, "current_tool", undefined) || changed;
        // Background work keeps running past its child turns; only a
        // foreground run ends here.
        if (record.background !== true) {
          changed = put(record, "status", "completed") || changed;
        }
        if (changed) record.version += 1;
        return changed;
      }
      case "turn_failed": {
        if (!this.isLive(record)) return false;
        let changed = put(record, "child_turn_state", "failed");
        changed = put(record, "current_tool", undefined) || changed;
        changed = put(record, "error", event.ev.error_message) || changed;
        const note = event.ev.error_message.replace(/\s+/g, " ").trim();
        changed =
          this.pushHistory(record, `✗ ${note.slice(0, HISTORY_TEXT_CHARS)}`) || changed;
        if (record.background !== true) {
          changed = put(record, "status", "failed") || changed;
        }
        if (changed) record.version += 1;
        return changed;
      }
      default:
        return false;
    }
  }

  /**
   * Extension lifecycle labels (`posoco_ext_subagent` customs):
   * `spawned` carries model/effort and the run's background mode,
   * `background_spawned` adds the task id, `background_exited` is the
   * actual exit (best-effort state), `background_terminal` the
   * authoritative classification. Unknown sources and labels are no-ops.
   */
  private applyCustom(
    record: SubagentActivity,
    ev: CetasEvent & { type: "custom" },
    parentCall: string,
  ): boolean {
    if (ev.source !== "posoco_ext_subagent") return false;
    const data =
      typeof ev.data === "object" && ev.data !== null
        ? (ev.data as Record<string, unknown>)
        : {};
    switch (ev.label) {
      case "spawned": {
        let changed = false;
        if (typeof data.model === "string") {
          changed = put(record, "model", data.model) || changed;
        }
        if (typeof data.effort === "string") {
          changed = put(record, "effort", data.effort) || changed;
        }
        if (typeof data.background === "boolean") {
          changed = put(record, "background", data.background) || changed;
        }
        const spawnCall = parentCall !== "background" ? parentCall : undefined;
        if (spawnCall !== undefined && spawnCall !== this.runIdentity(record)) {
          // Changed parent call: an explicit new run (resume).
          this.beginRun(record, spawnCall);
          return true;
        }
        // Same-call repeat spawn (or identity-less "background" envelope):
        // idempotent adoption only — the run is not reset.
        if (changed) record.version += 1;
        return changed;
      }
      case "background_spawned": {
        // Supplements the current run's background identity; never rekeys
        // the record onto the "background" pseudo call.
        let changed = put(record, "background", true);
        if (typeof data.task_id === "string") {
          changed = put(record, "task_id", data.task_id) || changed;
        }
        if (changed) record.version += 1;
        return changed;
      }
      case "background_exited": {
        // The authoritative terminal outranks the best-effort exit — a late
        // exit must not rewrite its classification.
        if (record.terminal_received) return false;
        let changed = put(record, "exited", true);
        const word = typeof data.state === "string" ? data.state : undefined;
        if (word !== undefined) {
          changed = put(record, "terminal_state", word) || changed;
          const coarse = coarseTerminal(word);
          if (coarse !== undefined) changed = put(record, "status", coarse) || changed;
        }
        if (typeof data.detail === "string") {
          changed = put(record, "error", data.detail) || changed;
        }
        changed = put(record, "current_tool", undefined) || changed;
        if (!changed) return false;
        this.pushHistory(
          record,
          `${record.status === "completed" ? "✓" : "✗"} exited ${word ?? "unknown"}`,
        );
        record.version += 1;
        return true;
      }
      case "background_terminal": {
        // Authoritative and exactly once per run: repeats never mutate.
        if (record.terminal_received) return false;
        let changed = put(record, "terminal_received", true);
        changed = put(record, "exited", true) || changed;
        const word = typeof data.state === "string" ? data.state : undefined;
        if (word !== undefined) {
          changed = put(record, "terminal_state", word) || changed;
          const coarse = coarseTerminal(word);
          if (coarse !== undefined) changed = put(record, "status", coarse) || changed;
        }
        if (typeof data.summary === "string") {
          changed = put(record, "summary", data.summary) || changed;
        }
        changed = put(record, "current_tool", undefined) || changed;
        if (!changed) return false;
        const summary =
          typeof data.summary === "string"
            ? data.summary.replace(/\s+/g, " ").trim().slice(0, HISTORY_TEXT_CHARS)
            : "";
        this.pushHistory(
          record,
          `${record.status === "completed" ? "✓" : "✗"} delivered ${word ?? "unknown"}${
            summary.length > 0 ? ` — ${summary}` : ""
          }`,
        );
        record.version += 1;
        return true;
      }
      default:
        // Unknown lifecycle label: no state, no version change.
        return false;
    }
  }

  /** Bounded append; consecutive duplicate entries collapse. True if added. */
  private pushHistory(record: SubagentActivity, entry: string): boolean {
    if (record.history[record.history.length - 1] === entry) return false;
    record.history.push(entry);
    if (record.history.length > HISTORY_MAX) {
      record.history.splice(0, record.history.length - HISTORY_MAX);
    }
    return true;
  }
}
