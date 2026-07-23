/**
 * event-router.ts — single handleEvent(CetasEvent) dispatch.
 *
 * Owns the live state for the turn currently in flight:
 *   - streaming-ui controller (accumulates thinking + text)
 *   - per-tool-call-id ToolRow map
 *   - status indicator callbacks
 *
 * DESIGN CHANGE (2026-07-23):
 *   - Streaming components are added to the transcript ONCE and never removed.
 *     No more showStreamingDraft/hideStreamingDraft — those caused splice-
 *     induced screen clearing and scroll jumps.
 *   - `stream_chunk` events carry a `kind` field ("reasoning" | "text").
 *     First reasoning chunk creates a ThinkingComponent; first text chunk
 *     finalizes thinking and creates an AssistantMessage.
 *   - `message_end` handles the non-streaming fallback path where no
 *     stream_chunks arrived (create both components from the full message).
 */

import { Container, type Component } from "@earendil-works/pi-tui";
import type { BridgeMessage, CetasEvent } from "../events.ts";
import {
  errorNotice,
  systemNotice,
  ToolRow,
} from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";
import { AssistantMessage } from "../transcript/components.ts";
import { StreamingUIController } from "./streaming-ui.ts";

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
   * Created fresh in `beginTurn()`, ended + nulled in `endTurn()`. This is the
   * structural fix for the "second turn overwrites first answer" bug: each
   * turn owns an isolated controller with isolated component references, so a
   * new turn always allocates fresh `AssistantMessage` / `ThinkingComponent`
   * instances instead of reusing the previous turn's. Mirrors pi's
   * `streamingComponent` reference model and kimi-code's `_streamingBlock`.
   */
  private stream: StreamingUIController | null = null;
  private toolRows = new Map<string, ToolRow>();
  private inTurn = false;
  /** Text finalized by message_end, promoted into transcript on turn_completed. */
  private pendingAssistantText = "";
  private pendingAssistantReasoning = "";

  constructor(private readonly cb: EventRouterCallbacks) {}

  /** Dispatch one parsed event. No-op for events we don't handle. */
  handleEvent(ev: CetasEvent): void {
    switch (ev.type) {
      case "turn_started":
        this.beginTurn(ev.session_id);
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
      case "message_start":
        // message_start is not emitted by current MoonBit bridge; handle
        // defensively in case a future version adds it.
        this.handleMessageEnd(ev.message);
        break;
      case "message_update":
        // message_update is not emitted by current MoonBit bridge; handle
        // defensively as a full-content replace.
        this.handleStreamContent(ev.message);
        break;
      case "tool_call_started":
        this.handleToolCallStarted(ev.tool_call_id, ev.tool_name, ev.args);
        break;
      case "tool_call_update":
        // Partial results not rendered in MVP — ignore.
        break;
      case "tool_call_completed":
        this.handleToolCallCompleted(ev.tool_call_id, ev.result, ev.is_error);
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
      default:
        break;
    }
    this.cb.requestRender();
  }

  // -- stream_chunk handling (streaming reasoning + text deltas) ----------

  private handleStreamChunk(ev: CetasEvent & { type: "stream_chunk" }): void {
    const s = this.stream;
    if (!s) return;
    if (ev.kind === "reasoning") {
      // First reasoning chunk? Create ThinkingComponent in live mode.
      if (!s.hasThinking) {
        const comp = new ThinkingComponent("", "live");
        this.cb.addTranscriptChild(comp);
        s.attachThinking(comp);
      }
      s.appendReasoning(ev.raw);
    } else {
      // First text chunk? Finalize thinking (if active) and create text component.
      if (s.hasThinking && !s.isThinkingFinalized) {
        s.finalizeThinking();
      }
      if (!s.hasText) {
        const comp = new AssistantMessage("");
        this.cb.addTranscriptChild(comp);
        s.attachText(comp);
      }
      s.appendText(ev.raw);
    }
  }

  // -- message_end / message_update full-content handling -----------------

  /**
   * Handle full-content message (message_end / message_start).
   * Two paths:
   *   1. Streaming already happened (components exist) → just finalize.
   *   2. Non-streaming (no components) → create components from message data.
   */
  private handleMessageEnd(msg: BridgeMessage): void {
    const s = this.stream;
    if (!s) return;
    const reasoning = (msg.reasoning ?? "").trim();
    const text = msg.content
      .filter((b) => b.type === "text")
      .map((b) => b.text)
      .join("\n\n");

    // Path A: streaming already created components — just finalize.
    if (s.hasThinking || s.hasText) {
      if (s.hasThinking && !s.isThinkingFinalized) {
        s.finalizeThinking();
      }
      const finalized = s.end();
      this.pendingAssistantText = finalized.text;
      this.pendingAssistantReasoning = finalized.thinking;
      return;
    }

    // Path B: non-streaming — create components from the full message.
    if (reasoning) {
      const comp = new ThinkingComponent(reasoning, "finalized");
      this.cb.addTranscriptChild(comp);
      s.attachThinking(comp);
      s.setFullThinking(reasoning);
    }
    if (text) {
      const comp = new AssistantMessage(text);
      this.cb.addTranscriptChild(comp);
      s.attachText(comp);
      s.setFullText(text);
    }
    if (reasoning && s.hasThinking) {
      s.finalizeThinking();
    }
    const finalized = s.end();
    this.pendingAssistantText = finalized.text || text;
    this.pendingAssistantReasoning = finalized.thinking || reasoning;
  }

  /**
   * Handle message_update (full content replace — not emitted by current
   * bridge, but handle defensively for future wire compatibility).
   */
  private handleStreamContent(msg: BridgeMessage): void {
    const s = this.stream;
    if (!s) return;
    const reasoning = (msg.reasoning ?? "").trim();
    const text = msg.content
      .filter((b) => b.type === "text")
      .map((b) => b.text)
      .join("\n\n");

    if (reasoning) {
      if (!s.hasThinking) {
        const comp = new ThinkingComponent("", "live");
        this.cb.addTranscriptChild(comp);
        s.attachThinking(comp);
      }
      s.setFullThinking(reasoning);
    }
    if (text) {
      if (!s.hasText) {
        // First text content in this update — finalize thinking first.
        if (s.hasThinking && !s.isThinkingFinalized) {
          s.finalizeThinking();
        }
        const comp = new AssistantMessage("");
        this.cb.addTranscriptChild(comp);
        s.attachText(comp);
      }
      s.setFullText(text);
    }
  }

  // -- tool call lifecycle -------------------------------------------------

  private handleToolCallStarted(
    toolCallId: string,
    toolName: string,
    args: unknown,
  ): void {
    const row = new ToolRow(toolName, args, this.cb.cwd, () =>
      this.cb.requestRender(),
    );
    this.toolRows.set(toolCallId, row);
    this.cb.addTranscriptChild(row);
  }

  private handleToolCallCompleted(
    toolCallId: string,
    result: string,
    isError: boolean,
  ): void {
    const row = this.toolRows.get(toolCallId);
    if (row) {
      row.setResult(result, isError);
    }
  }

  // -- turn lifecycle ------------------------------------------------------

  private beginTurn(_sessionId: string): void {
    this.inTurn = true;
    // Fresh controller per turn: null component references guarantee a new
    // turn allocates new AssistantMessage/ThinkingComponent instances instead
    // of mutating (overwriting) the previous turn's frozen components.
    this.stream = new StreamingUIController(() => this.cb.requestRender());
    this.toolRows.clear();
    this.pendingAssistantText = "";
    this.pendingAssistantReasoning = "";
    this.cb.setStatus("working", "thinking");
  }

  private endTurn(): void {
    this.inTurn = false;

    // If message_end never arrived (edge case: turn completed without model
    // response), promote whatever we have.
    if (this.pendingAssistantText) {
      // Streaming already created components in the transcript, so nothing
      // to promote. But in the edge case where no streaming or message_end
      // happened, this is a no-op guard.
      this.pendingAssistantText = "";
      this.pendingAssistantReasoning = "";
    }

    // Flush + drop the per-turn controller. Its components stay mounted in
    // the transcript (frozen), but the references are released so the next
    // turn's controller starts clean.
    this.stream?.abort();
    this.stream = null;
    this.cb.setStatus("idle");
    this.toolRows.clear();
  }
}
