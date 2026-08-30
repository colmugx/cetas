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
 *   - Pending calls are keyed by wire id when known, else `#<index>` until
 *     an id-bearing fragment re-keys them. Concurrent calls are
 *     disambiguated by index upstream; keys make them distinct here.
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
  private pending = new Map<string, PendingCall>();
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
    let entry = this.findPending(index, id);
    if (!entry) {
      entry = {
        id,
        index,
        name,
        rawArgs: "",
        row: this.factory.createStreamingRow(index, id, name),
      };
      this.pending.set(this.key(id, index), entry);
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
    const entry =
      this.pending.get(toolCallId) ??
      (this.pending.size === 1
        ? this.pending.values().next().value
        : undefined);
    if (!entry) return null;
    // Adoption consumes the entry regardless of which key held it.
    this.pending.delete(this.key(entry.id, entry.index));
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
    this.pending.clear();
  }

  // -- internal -------------------------------------------------------------

  private key(id: string | undefined, index: number): string {
    return id ?? `#${index}`;
  }

  /**
   * Locate the pending call a fragment belongs to. Direct key hits first,
   * then the unique pending entry at this index — continuation fragments
   * normally carry ONLY the index (OpenAI convention), so they must find
   * rows originally keyed by the id-bearing first fragment. An id-bearing
   * fragment claims its index-mate and re-keys it.
   */
  private findPending(
    index: number,
    id: string | undefined,
  ): PendingCall | undefined {
    let entry =
      id !== undefined ? this.pending.get(id) : undefined;
    if (!entry) {
      entry = this.pending.get(`#${index}`);
    }
    if (!entry) {
      for (const candidate of this.pending.values()) {
        if (candidate.index === index) {
          entry = candidate;
          break;
        }
      }
    }
    if (entry && id !== undefined) this.reKeyIfNeeded(entry, id);
    return entry;
  }

  /** Move an index-keyed entry under its newly learned id. */
  private reKeyIfNeeded(entry: PendingCall, id: string): void {
    if (entry.id === id) return;
    this.pending.delete(this.key(entry.id, entry.index));
    entry.id = id;
    this.pending.set(id, entry);
  }

  private scheduleFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushNow();
    }, this.flushMs);
  }

  private flushNow(): void {
    if (this.pending.size === 0) return;
    for (const entry of this.pending.values()) {
      // Lossiness may leave even the final buffer unparsable at its tail —
      // parsePartialJsonObject degrades gracefully either way.
      entry.row.setStreamingArgs(parsePartialJsonObject(entry.rawArgs), entry.name);
    }
    this.requestRender();
  }
}
