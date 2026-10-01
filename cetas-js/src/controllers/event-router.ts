/**
 * event-router.ts — single handleEvent(CetasEvent) dispatch.
 *
 * Owns the live state for the turn currently in flight:
 *   - streaming-ui controller (step-block accumulator)
 *   - per-tool-call-id ToolRow map
 *   - status indicator callbacks
 *
 * Streaming model:
 *   - The StreamingUIController owns step lifecycle + component creation via a
 *     StreamingComponentFactory wired here. Step boundaries are inferred from
 *     stream_chunk kind ordering inside the controller.
 *   - `message_end` is a POST-HOC REPLAY in this bridge
 *     (agent_puppet.mbt:456-535 reconstructs the final transcript after the
 *     pump finishes), NOT a live per-step signal. So handleMessageEnd is
 *     best-effort reconciliation: if the current step already streamed content,
 *     it only finalizes + closes the step and NEVER re-renders. Only when no
 *     stream_chunks arrived at all (non-streaming provider) does it build
 *     components from the full message to avoid duplicate replay rendering.
 */

import { type Component } from "@earendil-works/pi-tui";
import type { BridgeMessage, CetasEvent } from "../events.ts";
import type { SubagentActivityStore } from "./subagent-activity.ts";
import {
  errorNotice,
  systemNotice,
  ToolRow,
} from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";
import { AssistantMessage } from "../transcript/components.ts";
import { StreamingUIController, type StreamingComponentFactory } from "./streaming-ui.ts";
import {
  ToolStreamingController,
  type StreamingToolRowFactory,
} from "./tool-streaming.ts";

export interface EventRouterCallbacks {
  /** Append a component to the transcript Container. */
  addTranscriptChild(component: Component): void;
  /** Status indicator changes. */
  setStatus(kind: "working" | "retry" | "compaction" | "idle", message?: string): void;
  /** Force pi-tui to re-render. */
  requestRender(): void;
  cwd: string;
  /** Display label for a tool (e.g. `ext:name`); bare name when unknown. */
  toolLabel(toolName: string): string;
  /** Global ctrl+o state — new tool rows honor it from construction. */
  initialToolExpanded(): boolean;
  /**
   * The app redirected the live session (e.g. compact-NewThread). Optional:
   * hosts that don't follow redirects still get the notice rendering.
   */
  onSessionRedirect?(from: string, to: string): void;
  /**
   * One tagged child-run event from an embedded subagent. Optional: hosts
   * without subagent live-display simply omit it (events are dropped).
   */
  onSubagentEvent?(ev: CetasEvent & { type: "subagent_event" }): void;
  /**
   * Shell-owned subagent activity store, handed to tool rows through
   * ToolRowOptions so the `agent` renderer reads child snapshots from the
   * host's instance. Optional: hosts without subagent live-display omit it.
   */
  subagentActivity?: SubagentActivityStore;
  /**
   * Host visibility gate for live subagent row refreshes: the shell answers
   * whether `row` is safely on-screen (no overlay, stable layout, inside the
   * painted viewport — see TerminalShell.canRefreshSubagentRow). Optional:
   * absent means always allowed, so plain unit harnesses refresh without a
   * terminal.
   */
  canRefreshSubagentRow?(row: ToolRow): boolean;
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
  /**
   * Per-turn streaming tool-args controller. Same lifecycle contract as
   * `stream`: fresh per turn, dropped in endTurn(). Adopted rows move into
   * `toolRows` so `tool_call_completed` keeps routing to them.
   */
  private toolStream: ToolStreamingController | null = null;
  private toolRows = new Map<string, ToolRow>();

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
      case "tool_args_delta":
        this.toolStream?.onArgsDelta(ev.index, ev.id, ev.name, ev.delta);
        break;
      case "tool_call_completed": {
        // The terminal UI represents media attachments as compact text chips.
        const chips = (ev.images ?? [])
          .map((img) => `\n🖼 ${img.media_type} ~${Math.ceil((img.data.length * 3) / 4 / 1024)} KB`)
          .join("");
        this.handleToolCallCompleted(
          ev.tool_call_id,
          ev.result + chips,
          ev.is_error,
          ev.structured,
        );
        break;
      }
      case "tool_call_deferred":
        this.cb.addTranscriptChild(
          systemNotice(`⏸ deferred: ${ev.tool_name} (${ev.reason})`),
        );
        break;
      case "session_redirect":
        this.cb.addTranscriptChild(
          systemNotice(`↻ redirect: ${ev.from} → ${ev.to}`),
        );
        this.cb.onSessionRedirect?.(ev.from, ev.to);
        break;
      case "subagent_event":
        // Child-run events never touch the parent's turn/stream state — the
        // subscriber owns folding and row invalidation.
        this.cb.onSubagentEvent?.(ev);
        return;
      case "model_invoked":
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

  // -- message_end full-content handling -----------------------------------

  /**
   * Best-effort reconciliation for the post-hoc `message_end` replay.
   *
   * `message_end` is NOT a live per-step signal in this bridge — the pump
   * reconstructs the final transcript after it finishes and replays one
   * `message_end` per AssistantMessage. By the time it
   * arrives, streaming has usually already rendered that message's content.
   *
   * Two paths:
   *   A. Streaming happened this turn (any stream_chunk arrived) → reconcile
   *      only: finalize + close the current step. NEVER re-render (would
   *      duplicate reasoning/text). This gate is turn-scoped, not
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

  // -- tool call lifecycle -------------------------------------------------

  private handleToolCallStarted(
    toolCallId: string,
    toolName: string,
    args: unknown,
  ): void {
    // Streaming reconciliation: deltas for this call reached us BEFORE the
    // started event, so a pending row may already be mounted. Adoption hands
    // the row the authoritative full args (replacement, not merge — the
    // chunk channel is lossy) and registers it here so completed results
    // route normally. Without prior deltas this returns null and the classic
    // path below runs unchanged (history replay / non-streaming providers).
    const adopted = this.toolStream?.onCallStarted(toolCallId, toolName, args);
    if (adopted) {
      // Fragments may have mounted the row keyed `#<index>`; renderers key
      // live lookups on ctx.toolCallId (the `agent` row resolves child
      // snapshots by parent_call), so adoption lands the authoritative id.
      adopted.setCallId(toolCallId);
      this.toolRows.set(toolCallId, adopted);
      this.cb.setStatus("working", `running ${toolName}`);
      return;
    }
    const row = new ToolRow(
      toolName,
      toolCallId,
      args,
      this.cb.cwd,
      () => this.cb.requestRender(),
      this.cb.toolLabel(toolName),
      this.cb.initialToolExpanded(),
      { subagentActivity: this.cb.subagentActivity },
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
    // another tool call (overwrites this) or the follow-up model stream. A
    // late completion after endTurn must not resurrect the working status —
    // nothing would reset it.
    if (this.stream !== null) {
      this.cb.setStatus("working", "waiting for model");
    }
  }

  // -- live subagent row refresh -------------------------------------------

  /**
   * Refresh the pending `agent` row for one parent call (called by the shell
   * when a child event lands). Only a row of the CURRENT turn that has not
   * finished qualifies — `toolRows` is cleared at turn end and
   * ToolRow.refreshLive() refuses finished rows — and the host visibility
   * gate (cb.canRefreshSubagentRow) can veto off-screen refreshes. Returns
   * whether a row was actually refreshed.
   */
  refreshSubagentRow(parentCall: string): boolean {
    const row = this.toolRows.get(parentCall);
    if (row === undefined) return false;
    if (
      this.cb.canRefreshSubagentRow !== undefined &&
      !this.cb.canRefreshSubagentRow(row)
    ) {
      return false;
    }
    return row.refreshLive();
  }

  /**
   * One-stop 1s tick for the shell: refresh every foreground child's parent
   * row still live this turn. Walks the store's running set, skips
   * background children (they render in the header, never as transcript
   * rows), dedupes by parent call (several children may share one `agent`
   * call), and applies the same visibility gate as refreshSubagentRow.
   * Returns the number of rows refreshed.
   */
  refreshRunningSubagents(): number {
    const running = this.cb.subagentActivity?.running() ?? [];
    const seen = new Set<string>();
    let refreshed = 0;
    for (const record of running) {
      if (record.background === true) continue;
      const parentCall = record.parent_call;
      if (parentCall.length === 0 || parentCall === "background") continue;
      if (seen.has(parentCall)) continue;
      seen.add(parentCall);
      if (this.refreshSubagentRow(parentCall)) refreshed += 1;
    }
    return refreshed;
  }

  // -- turn lifecycle ------------------------------------------------------

  private beginTurn(): void {
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
    // Streaming tool rows mount via the same pattern: the controller owns
    // accumulation + throttled flushes; the factory only mounts components.
    const toolFactory: StreamingToolRowFactory = {
      createStreamingRow: (index, id, name) => {
        const displayName = name ?? "";
        const row = new ToolRow(
          displayName,
          id ?? `#${index}`,
          {},
          this.cb.cwd,
          () => this.cb.requestRender(),
          displayName.length > 0 ? this.cb.toolLabel(displayName) : undefined,
          this.cb.initialToolExpanded(),
          {
            streaming: true,
            labelFor: (n) => this.cb.toolLabel(n),
            // Same injection as the classic path: an adopted `agent` row
            // must reach live child data with the same options.
            subagentActivity: this.cb.subagentActivity,
          },
        );
        this.cb.addTranscriptChild(row);
        return row;
      },
    };
    this.toolStream = new ToolStreamingController(
      () => this.cb.requestRender(),
      toolFactory,
    );
    this.toolRows.clear();
    this.cb.setStatus("working", "thinking");
  }

  private endTurn(): void {
    // Close any open step (flush + finalize), then drop the per-turn
    // controller. Its mounted components stay in the transcript (frozen); the
    // references are released so the next turn's controller starts clean.
    this.stream?.end();
    this.stream = null;
    // Drop pending tool-args state; mounted rows stay as frozen children.
    this.toolStream?.endTurn();
    this.toolStream = null;
    this.cb.setStatus("idle");
    this.toolRows.clear();
  }
}
