/**
 * question-activity.ts — host-side fold of the non-blocking ask extension's
 * `question_event` stream (`Asked` / `Answered`).
 *
 * A question is a live obligation, not a transcript entry: `asked` parks it,
 * the human's answer (or expiry, classified by the extension) removes it.
 * Records are tagged with the owning session so a shell never shows another
 * session's pending question, and ids survive removal so a replayed event
 * cannot reopen a question that was already answered.
 *
 * Answers travel as ordinary user input; the extension owns the model-facing
 * `[question-reply …]` envelope and delivers it exactly once. This store only
 * decides what the user still owes an answer to.
 *
 * Pure logic — no TUI state, no timers — so it is unit-testable. The owning
 * shell constructs its own instance; nothing here is process-global.
 */

import type { QuestionEventData } from "../events.ts";

export interface PendingQuestion {
  /** Registry-minted id (`question-3`). */
  readonly id: string;
  /** Short UI form (`@q3`). */
  readonly short_id: string;
  /** Asking tool call id, for correlating with the `notify_user` row. */
  readonly origin_call: string;
  /** The question text. */
  readonly text: string;
  readonly kind: "input" | "confirm" | "select";
  /** Offered options; empty unless `kind` is `select`. */
  readonly options: readonly string[];
  readonly asked_at: number;
  /** Absolute deadline in epoch milliseconds; 0 disables expiry. */
  readonly deadline_at: number;
  /** Owning session ("" when the event arrived without one). */
  readonly session: string;
}

function normalizeKind(word: string): "input" | "confirm" | "select" {
  return word === "confirm" || word === "select" ? word : "input";
}

function stringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function finiteOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export class QuestionActivityStore {
  private readonly pending = new Map<string, PendingQuestion>();
  /** Ids that were parked once; a repeat `asked` never reopens them. */
  private readonly seen = new Set<string>();
  /** Ids answered or withdrawn; `asked` replays are dropped wholesale. */
  private readonly settled = new Set<string>();

  /** `now` is injectable so expiry display is testable. */
  constructor(private readonly now: () => number = Date.now) {}

  get(id: string): PendingQuestion | undefined {
    return this.pending.get(id);
  }

  /** Pending questions of one session, oldest ask first. */
  pendingFor(session: string): readonly PendingQuestion[] {
    return [...this.pending.values()]
      .filter((question) => question.session === session)
      .sort((a, b) => a.asked_at - b.asked_at);
  }

  get size(): number {
    return this.pending.size;
  }

  /**
   * Fold one `question_event`; returns whether visible state changed.
   * Unknown labels are no-ops so an older host tolerates a newer extension.
   * `question_closed` is the plain-reply path: the human answered in
   * conversation without addressing the question, so no envelope will
   * arrive — the card just goes away.
   */
  apply(label: string, data: QuestionEventData | undefined, session: string): boolean {
    if (data === undefined) return false;
    switch (label) {
      case "question_asked": {
        if (typeof data.question_id !== "string" || data.question_id.length === 0) {
          return false;
        }
        const id = data.question_id;
        if (this.settled.has(id) || this.pending.has(id)) return false;
        if (this.seen.has(id)) {
          // Parked once, then withdrawn by a route that left no record:
          // re-parking would resurrect an obligation the user may already
          // have dismissed. Treat the replay as settled.
          this.settled.add(id);
          return false;
        }
        this.seen.add(id);
        this.pending.set(id, {
          id,
          short_id: typeof data.short_id === "string" ? data.short_id : "",
          origin_call: typeof data.origin_call === "string" ? data.origin_call : "",
          text: typeof data.question === "string" ? data.question : "",
          kind: normalizeKind(typeof data.kind === "string" ? data.kind : "input"),
          options: stringList(data.options),
          asked_at: finiteOr(data.asked_at, this.now()),
          deadline_at: finiteOr(data.deadline_at, 0),
          session,
        });
        return true;
      }
      case "question_answered":
      case "question_closed": {
        if (typeof data.question_id !== "string") return false;
        const id = data.question_id;
        this.seen.add(id);
        this.settled.add(id);
        return this.pending.delete(id);
      }
      default:
        return false;
    }
  }

  /**
   * Drop questions the host will never answer (session switch, shell
   * teardown). They are settled, not merely hidden: a late `asked` replay
   * must not bring them back.
   */
  withdraw(session?: string): boolean {
    let changed = false;
    for (const [id, question] of [...this.pending]) {
      if (session !== undefined && question.session !== session) continue;
      this.pending.delete(id);
      this.settled.add(id);
      changed = true;
    }
    return changed;
  }

  /**
   * Drop every question whose deadline passed, reporting the ids removed.
   * Display-only: the extension classifies expiry for the model; this just
   * stops the host from asking for an answer that can no longer be accepted.
   */
  expire(now = this.now()): readonly string[] {
    const expired: string[] = [];
    for (const [id, question] of [...this.pending]) {
      if (question.deadline_at <= 0 || now <= question.deadline_at) continue;
      this.pending.delete(id);
      this.settled.add(id);
      expired.push(id);
    }
    return expired;
  }

  clear(): void {
    this.pending.clear();
    this.settled.clear();
    this.seen.clear();
  }
}
