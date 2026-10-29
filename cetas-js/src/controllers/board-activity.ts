/**
 * board-activity.ts — live fold of the in-process Board ticket runs for the
 * Cetas Activities header.
 *
 * The Board server already polls `board.ticket.state` once per second. This
 * store is a pure projection of that state: it keeps only running runs, keeps
 * their stable first-seen order, and drops a run as soon as it leaves the
 * running state. It is an ephemeral header, not a durable run log.
 */

export interface BoardActivity {
  /** Stable header identity: task id plus phase. */
  readonly key: string;
  readonly task_id: string;
  readonly phase: string;
  readonly status: string;
  readonly steps: number;
  readonly current_tool?: string;
  readonly preview: string;
  readonly reasoning: string;
  /** Most recent activity row text, if any. */
  readonly last_activity?: string;
  /** First time this run was seen by the store (epoch ms). */
  readonly started_at: number;
  /** Stable first-appearance order. */
  readonly seq: number;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function number(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function activityText(value: unknown): string | undefined {
  const item = record(value);
  if (item === undefined) return undefined;
  const body = text(item.text);
  return body.length > 0 ? body : undefined;
}

export interface BoardPresence {
  readonly state: "idle" | "working" | "blocked";
  readonly running: number;
  readonly waiting_input: number;
  readonly attention: number;
  readonly message?: string;
}

function presenceFrom(state: unknown): BoardPresence {
  const root = record(state);
  const raw = root === undefined ? undefined : record(root.presence);
  if (raw === undefined) return { state: "idle", running: 0, waiting_input: 0, attention: 0 };
  const rawState = text(raw.state);
  const value = rawState === "blocked" || rawState === "working" ? rawState : "idle";
  const message = text(raw.message);
  return {
    state: value,
    running: number(raw.running),
    waiting_input: number(raw.waiting_input),
    attention: number(raw.attention),
    ...(message.length > 0 ? { message } : {}),
  };
}

export class BoardActivityStore {
  private readonly records = new Map<string, BoardActivity>();
  private readonly order = new Map<string, number>();
  private nextSeq = 0;
  private signatureText = "";
  private currentPresence: BoardPresence = {
    state: "idle",
    running: 0,
    waiting_input: 0,
    attention: 0,
  };

  /**
   * Replace the projection from one `board.ticket.state` payload.
   * Returns true only when the visible header data changed.
   */
  update(state: unknown): boolean {
    const root = record(state);
    this.currentPresence = presenceFrom(state);
    const runs = root === undefined ? undefined : root.runs;
    const next = new Map<string, BoardActivity>();
    if (Array.isArray(runs)) {
      for (const item of runs) {
        const run = record(item);
        if (run === undefined) continue;
        if (text(run.status) !== "running") continue;
        const taskId = text(run.task_id);
        if (taskId.length === 0) continue;
        const phase = text(run.phase);
        const key = `${taskId}:${phase}`;
        const activities = Array.isArray(run.activities) ? run.activities : [];
        const last = activityText(activities.at(-1));
        const existing = this.records.get(key);
        if (!this.order.has(key)) {
          this.order.set(key, this.nextSeq++);
        }
        const firstAt = number(record(activities[0])?.at_ms);
        const startedAt =
          existing?.started_at ?? (firstAt > 0 ? firstAt : Date.now());
        const currentTool = text(run.current_tool);
        next.set(key, {
          key,
          task_id: taskId,
          phase,
          status: "running",
          steps: number(run.steps),
          current_tool: currentTool.length > 0 ? currentTool : undefined,
          preview: text(run.preview),
          reasoning: text(run.reasoning),
          last_activity: last,
          started_at: startedAt,
          seq: this.order.get(key)!,
        });
      }
    }

    const signature = JSON.stringify(
      [...next.values()].map((item) => [
        item.key,
        item.steps,
        item.current_tool ?? "",
        item.preview,
        item.reasoning,
        item.last_activity ?? "",
      ]),
    );
    this.records.clear();
    for (const [key, value] of next) this.records.set(key, value);
    // Drop order entries for runs that are no longer live; if the same task
    // starts again it gets a fresh seq rather than a recycled one.
    for (const key of [...this.order.keys()]) {
      if (!next.has(key)) this.order.delete(key);
    }
    if (signature === this.signatureText) return false;
    this.signatureText = signature;
    return true;
  }

  presence(): BoardPresence {
    return this.currentPresence;
  }

  running(): readonly BoardActivity[] {
    return [...this.records.values()].sort((a, b) => a.seq - b.seq);
  }

  clear(): boolean {
    const had = this.records.size > 0;
    this.records.clear();
    this.order.clear();
    this.signatureText = "";
    this.currentPresence = { state: "idle", running: 0, waiting_input: 0, attention: 0 };
    return had;
  }
}
