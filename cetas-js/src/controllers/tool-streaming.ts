/**
 * tool-streaming.ts — live accumulator for streamed tool-call arguments.
 *
 * MODEL:
 *   - ModelPorts emit `tool_args_delta` fragments BEFORE the committed
 *     `tool_call_started` for the same call (the puppet flushes its chunk
 *     queue before every committed event). While a `write` call streams,
 *     its file content renders line by line, then collapses at start.
 *   - The chunk channel is LOSSY under backpressure (bounded queue, oldest
 *     dropped): accumulated args may have gaps. Display is best-effort;
 *     `tool_call_started` carries the complete authoritative args and
 *     REPLACES the accumulated state on adoption.
 *   - Pending calls are indexed independently by upstream index and wire id,
 *     avoiding string-key collisions and linear searches on continuation
 *     fragments. The committed id is authoritative at adoption time.
 *   - `onCallStarted` returns the adopted ToolRow so the router can take
 *     over result routing; unknown started ids return null and the router
 *     builds a fresh row exactly as in the non-streaming path (history
 *     replay / providers without arg deltas).
 *
 * Mount + throttling mirror StreamingUIController: rows mount immediately
 * via factory, deltas only accumulate raw text, and a dirty-set flush at
 * TOOL_STREAMING_FLUSH_MS parses partial JSON once per interval.
 */

import { ToolRow } from "../transcript/components.ts";
import { parsePartialJsonObject } from "./partial-json.ts";

export const TOOL_STREAMING_FLUSH_MS = 50;

/** Factory the host supplies to mount streaming rows into the transcript. */
export interface StreamingToolRowFactory {
  /** Mount a ToolRow in streaming state for this pending call. */
  createStreamingRow(
    index: number,
    id: string | undefined,
    name: string | undefined,
  ): ToolRow;
}

interface PendingCall {
  id?: string;
  index: number;
  name?: string;
  rawArgs: string;
  row: ToolRow;
}

export class ToolStreamingController {
  /** Index is present even when the lossy stream omitted the call id. */
  private readonly pendingByIndex = new Map<number, PendingCall>();
  /** Known wire ids are indexed separately to avoid collisions with indices. */
  private readonly pendingById = new Map<string, PendingCall>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly requestRender: () => void,
    private readonly factory: StreamingToolRowFactory,
    private readonly flushMs = TOOL_STREAMING_FLUSH_MS,
  ) {}

  // -- push model (tool_args_delta fragments) -------------------------------

  /**
   * Feed one fragment. Find-or-create the pending call's row, append the
   * delta text, mark it dirty for the next throttled flush. Safe for any
   * field combination: later fragments may repeat id/name or carry none.
   */
  onArgsDelta(
    index: number,
    id: string | undefined,
    name: string | undefined,
    delta: string | undefined,
  ): void {
    // Continuations normally carry only the index. Both paths are O(1).
    let entry =
      (id === undefined ? undefined : this.pendingById.get(id)) ??
      this.pendingByIndex.get(index);
    if (entry === undefined) {
      entry = {
        index,
        name,
        rawArgs: "",
        row: this.factory.createStreamingRow(index, id, name),
      };
      this.pendingByIndex.set(index, entry);
    }
    if (id !== undefined && entry.id !== id) {
      if (entry.id !== undefined) this.pendingById.delete(entry.id);
      entry.id = id;
      this.pendingById.set(id, entry);
    }
    if (delta !== undefined && delta.length > 0) {
      entry.rawArgs += delta;
    }
    if (name !== undefined && entry.name === undefined) {
      entry.name = name;
    }
    this.scheduleFlush();
  }

  /**
   * Authoritative call commitment. Adopts a matching pending row (by id,
   * or the sole pending row when fragments never carried an id), removes
   * it from pending, and hands the row the full authoritative args.
   * Returns the adopted row for the router to register under the real
   * call id — or null when nothing sensible matches, so the router builds
   * a fresh ToolRow exactly as in the non-streaming path.
   */
  onCallStarted(
    toolCallId: string,
    toolName: string,
    args: unknown,
  ): ToolRow | null {
    // The authoritative id wins. Never claim a different identified row.
    // Only one id-less provisional row may be adopted, and a known streamed
    // tool name must agree with the committed name.
    let entry = this.pendingById.get(toolCallId);
    if (entry === undefined && this.pendingByIndex.size === 1) {
      const sole = this.pendingByIndex.values().next().value;
      if (
        sole !== undefined &&
        sole.id === undefined &&
        (sole.name === undefined || sole.name === toolName)
      ) entry = sole;
    }
    if (entry === undefined) return null;
    this.pendingByIndex.delete(entry.index);
    if (entry.id !== undefined) this.pendingById.delete(entry.id);
    entry.row.markCallStarted(args, toolName);
    return entry.row;
  }

  // -- lifecycle ------------------------------------------------------------

  /**
   * End the turn: drop all pending state and timers. Mounted rows stay in
   * the transcript as frozen children (a started-less stream freezes with
   * its last partial view — accepted cosmetic under lossiness).
   */
  endTurn(): void {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.pendingByIndex.clear();
    this.pendingById.clear();
  }

  // -- internal -------------------------------------------------------------

  private scheduleFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushNow();
    }, this.flushMs);
  }

  private flushNow(): void {
    if (this.pendingByIndex.size === 0) return;
    for (const entry of this.pendingByIndex.values()) {
      // Lossiness may leave even the final buffer unparsable at its tail —
      // parsePartialJsonObject degrades gracefully either way.
      entry.row.setStreamingArgs(parsePartialJsonObject(entry.rawArgs), entry.name);
    }
    this.requestRender();
  }
}
