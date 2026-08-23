/**
 * event-router.ts — single handleEvent(CetasEvent) dispatch.
 *
 * Owns the live state for the turn currently in flight:
 *   - streaming-ui controller (step-block accumulator)
 *   - per-tool-call-id ToolRow map
 *   - status indicator callbacks
 *
 * MODEL (2026-07-31):
 *   - The StreamingUIController owns step lifecycle + component creation via a
 *     StreamingComponentFactory wired here. Step boundaries are inferred from
 *     stream_chunk kind ordering inside the controller.
 *   - `message_end` is a POST-HOC REPLAY in this bridge
 *     (agent_puppet.mbt:456-535 reconstructs the final transcript after the
 *     pump finishes), NOT a live per-step signal. So handleMessageEnd is
 *     best-effort reconciliation: if the current step already streamed content,
 *     it only finalizes + closes the step and NEVER re-renders. Only when no
 *     stream_chunks arrived at all (non-streaming provider) does it build
 *     components from the full message. This is the fix for Bug #2-b (replayed
 *     reasoning/text was rendered a second time).
 */

import { type Component } from "@earendil-works/pi-tui";
import type { BridgeMessage, CetasEvent } from "../events.ts";
import {
  errorNotice,
  systemNotice,
  ToolRow,
} from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";
import { AssistantMessage } from "../transcript/components.ts";
import { StreamingUIController, type StreamingComponentFactory } from "./streaming-ui.ts";

export interface EventRouterCallbacks {
  /** Append a component to the transcript Container. */
  addTranscriptChild(component: Component): void;
  /** Status indicator changes. */
  setStatus(kind: "working" | "retry" | "compaction" | "idle", message?: string): void;
  /** Force pi-tui to re-render. */
  requestRender(): void;
  /** Current working dir — used as ToolRow context. */
  cwd: string;
}

export class EventRouter {
  /**
   * Per-turn streaming controller. `null` between turns.
   *
   * Created fresh in `beginTurn()`, aborted + nulled in `endTurn()`. Each turn
   * owns an isolated controller, so a new turn always opens fresh steps instead
   * of mutating the previous turn's frozen components.
   */
  private stream: StreamingUIController | null = null;
  private toolRows = new Map<string, ToolRow>();
  private inTurn = false;

  constructor(private readonly cb: EventRouterCallbacks) {}

  /** Dispatch one parsed event. No-op for events we don't handle. */
  handleEvent(ev: CetasEvent): void {
    switch (ev.type) {
      case "turn_started":
        this.beginTurn();
        break;
      case "turn_completed":
        this.endTurn();
        break;
      case "turn_failed":
        this.cb.addTranscriptChild(errorNotice(ev.error_message));
        this.endTurn();
        break;
      case "stream_chunk":
        this.handleStreamChunk(ev);
        break;
      case "message_end":
        this.handleMessageEnd(ev.message);
        break;
      case "tool_call_started":
        this.handleToolCallStarted(ev.tool_call_id, ev.tool_name, ev.args);
        break;
      case "tool_call_completed":
        this.handleToolCallCompleted(
          ev.tool_call_id,
          ev.result,
          ev.is_error,
          ev.structured,
        );
        break;
      case "tool_call_deferred":
        this.cb.addTranscriptChild(
          systemNotice(`⏸ deferred: ${ev.tool_name} (${ev.reason})`),
        );
        break;
      case "session_redirect":
        this.cb.addTranscriptChild(
          systemNotice(`↻ redirect: ${ev.from} → ${ev.to}`),
        );
        break;
      case "model_invoked":
        // Token-usage surfacing is a future enhancement.
        break;
      case "custom":
        this.cb.addTranscriptChild(
          systemNotice(`· ${ev.source}/${ev.label}`),
        );
        break;
      case "config_changed":
        this.cb.addTranscriptChild(
          systemNotice(`⚙ ${ev.field}: ${ev.old} → ${ev.new}`),
        );
        break;
      case "config_warning":
        this.cb.addTranscriptChild(
          systemNotice(`⚠ ${ev.field}=${ev.value} — ${ev.reason}`),
        );
        break;
      default:
        break;
    }
    this.cb.requestRender();
  }

  // -- stream_chunk handling (streaming reasoning + text deltas) ----------

  private handleStreamChunk(ev: CetasEvent & { type: "stream_chunk" }): void {
    const s = this.stream;
    if (!s) return;
    // The controller owns step-boundary detection (text→reasoning = new step)
    // and component creation via the factory. The router just feeds deltas.
    if (ev.kind === "reasoning") {
      s.appendReasoning(ev.raw);
    } else {
      s.appendText(ev.raw);
    }
  }

  // -- message_end / message_update full-content handling -----------------

  /**
   * Best-effort reconciliation for the post-hoc `message_end` replay.
   *
   * `message_end` is NOT a live per-step signal in this bridge — the pump
   * reconstructs the final transcript after it finishes (agent_puppet.mbt
   * step 7) and replays one `message_end` per AssistantMessage. By the time it
   * arrives, streaming has usually already rendered that message's content.
   *
   * Two paths:
   *   A. Streaming happened this turn (any stream_chunk arrived) → reconcile
   *      only: finalize + close the current step. NEVER re-render (would
   *      duplicate reasoning/text — Bug #2-b). This gate is turn-scoped, not
   *      step-scoped, because step-boundary detection may have already closed
   *      the step before the replay arrives.
   *   B. No stream_chunks arrived at all this turn (non-streaming provider) →
   *      build components from the full message and close.
   */
  private handleMessageEnd(msg: BridgeMessage): void {
    const s = this.stream;
    if (!s) return;
    const reasoning = (msg.reasoning ?? "").trim();
    const text = msg.content
      .filter((b) => b.type === "text")
      .map((b) => b.text)
      .join("\n\n");

    // Path A: streaming happened this turn — reconcile only.
    if (s.hasStreamedThisTurn) {
      s.finalizeThinkingIfActive();
      s.closeStep();
      return;
    }

    // Path B: non-streaming — build components from the full message.
    if (reasoning || text) {
      if (reasoning) {
        const comp = new ThinkingComponent(reasoning, "finalized");
        this.cb.addTranscriptChild(comp);
        s.attachThinking(comp);
      }
      if (text) {
        const comp = new AssistantMessage(text);
        this.cb.addTranscriptChild(comp);
        s.attachText(comp);
      }
    }
    s.closeStep();
  }

  /**
   * Handle message_update (full content replace — not emitted by current
   * bridge, but handle defensively for future wire compatibility).
   *
   * Same dedup discipline as handleMessageEnd: if streaming happened this turn,
   * treat the full-replace as a no-op reconciliation; otherwise build from the
   * message.
   */
  private handleStreamContent(msg: BridgeMessage): void {
    const s = this.stream;
    if (!s) return;
    if (s.hasStreamedThisTurn) {
      // Streaming already rendered this turn — don't clobber with a replace.
      return;
    }
    const reasoning = (msg.reasoning ?? "").trim();
    const text = msg.content
      .filter((b) => b.type === "text")
      .map((b) => b.text)
      .join("\n\n");
    if (reasoning) {
      const comp = new ThinkingComponent("", "live");
      this.cb.addTranscriptChild(comp);
      s.attachThinking(comp);
      s.setFullThinking(reasoning);
    }
    if (text) {
      const comp = new AssistantMessage("");
      this.cb.addTranscriptChild(comp);
      s.attachText(comp);
      s.setFullText(text);
    }
  }

  // -- tool call lifecycle -------------------------------------------------

  private handleToolCallStarted(
    toolCallId: string,
    toolName: string,
    args: unknown,
  ): void {
    const row = new ToolRow(toolName, toolCallId, args, this.cb.cwd, () =>
      this.cb.requestRender(),
    );
    this.toolRows.set(toolCallId, row);
    this.cb.addTranscriptChild(row);
    // Phase feedback: without this the status stays "thinking" for the whole
    // turn and tool→model round-trips look like a stalled response.
    this.cb.setStatus("working", `running ${toolName}`);
  }

  private handleToolCallCompleted(
    toolCallId: string,
    result: string,
    isError: boolean,
    structured?: Record<string, unknown>,
  ): void {
    const row = this.toolRows.get(toolCallId);
    if (row) {
      row.setResult(result, isError, structured);
    }
    // Tool results go back to the model; the next visible activity is either
    // another tool call (overwrites this) or the follow-up model stream.
    this.cb.setStatus("working", "waiting for model");
  }

  // -- turn lifecycle ------------------------------------------------------

  private beginTurn(): void {
    this.inTurn = true;
    // Fresh controller per turn. The factory mounts new components into the
    // transcript on demand; a new turn's steps therefore allocate fresh
    // AssistantMessage/ThinkingComponent instances instead of mutating the
    // previous turn's frozen components.
    const factory: StreamingComponentFactory = {
      createThinking: () => {
        const comp = new ThinkingComponent("", "live");
        this.cb.addTranscriptChild(comp);
        return comp;
      },
      createText: () => {
        const comp = new AssistantMessage("");
        this.cb.addTranscriptChild(comp);
        return comp;
      },
      addTranscriptChild: (c) => this.cb.addTranscriptChild(c),
    };
    this.stream = new StreamingUIController(
      () => this.cb.requestRender(),
      factory,
    );
    this.toolRows.clear();
    this.cb.setStatus("working", "thinking");
  }

  private endTurn(): void {
    this.inTurn = false;

    // Close any open step (flush + finalize), then drop the per-turn
    // controller. Its mounted components stay in the transcript (frozen); the
    // references are released so the next turn's controller starts clean.
    this.stream?.end();
    this.stream = null;
    this.cb.setStatus("idle");
    this.toolRows.clear();
  }
}
