export type CursorFrame = {
  type: string;
  runtime_epoch?: string;
  session_id?: string;
  cursor?: number;
  high_water_cursor?: number;
  cursor_advance?: boolean;
};

export type CursorDecision =
  | { kind: "snapshot"; cursor: number; epoch: string }
  | { kind: "event"; cursor: number }
  | { kind: "unsequenced" }
  | { kind: "duplicate" }
  | { kind: "gap"; expected: number; received: number }
  | { kind: "epoch_changed"; previous: string; received: string };

export class SessionEventCursor {
  #epoch = "";
  #cursors = new Map<string, number>();

  epoch(): string {
    return this.#epoch;
  }

  cursor(sessionId: string): number {
    return this.#cursors.get(sessionId) ?? 0;
  }

  reset(): void {
    this.#epoch = "";
    this.#cursors.clear();
  }

  accept(frame: CursorFrame): CursorDecision {
    const sessionId = frame.session_id ?? "";
    const epoch = frame.runtime_epoch ?? "";
    const currentEpoch = this.#epoch;

    if (epoch && currentEpoch && epoch !== currentEpoch) {
      if (frame.type !== "session.snapshot") {
        return { kind: "epoch_changed", previous: currentEpoch, received: epoch };
      }
    }

    if (frame.type === "session.snapshot") {
      const epochChanged = Boolean(epoch && currentEpoch && epoch !== currentEpoch);
      if (epochChanged) this.#cursors.clear();
      if (epoch) this.#epoch = epoch;
      const cursor = frame.high_water_cursor ?? frame.cursor ?? 0;
      if (!Number.isSafeInteger(cursor) || cursor < 0) {
        return { kind: "unsequenced" };
      }
      const previous = this.cursor(sessionId);
      if (!epochChanged && cursor < previous) return { kind: "duplicate" };
      this.#cursors.set(sessionId, cursor);
      return { kind: "snapshot", cursor, epoch: this.#epoch };
    }

    if (epoch && !this.#epoch) this.#epoch = epoch;
    if (frame.cursor_advance !== true) return { kind: "unsequenced" };

    const cursor = frame.cursor;
    if (typeof cursor !== "number" || !Number.isSafeInteger(cursor) || cursor < 1) {
      return { kind: "unsequenced" };
    }
    const previous = this.cursor(sessionId);
    if (cursor <= previous) return { kind: "duplicate" };
    if (cursor !== previous + 1) {
      return { kind: "gap", expected: previous + 1, received: cursor };
    }
    this.#cursors.set(sessionId, cursor);
    return { kind: "event", cursor };
  }
}
