/**
 * streaming-ui.ts — step-block accumulator for streaming assistant output.
 *
 * MODEL:
 *   - One mutable "current step" slot holds the in-flight assistant message's
 *     reasoning + text components.
 *   - The transcript (host's transcriptContainer) is an append-only history:
 *     finalized step components stay mounted as frozen siblings and are NEVER
 *     mutated again. Finalization = the slot stops pointing at them, not a
 *     state transition on the component beyond `finalize()`.
 *   - Step boundaries are inferred from stream_chunk kind ordering (see
 *     {@link appendReasoning}), NOT from `message_end` — which is a delayed
 *     post-hoc replay in this bridge (agent_puppet.mbt:456-535), not a live
 *     per-step signal.
 *
 * This model fixes two bugs the old "one thinking + one text slot per TURN"
 * design had:
 *   - Bug #1: reasoning arriving after a tool call overwrote the previous
 *     step's ThinkingComponent instead of opening a new block.
 *   - Bug #2-b: the post-hoc `message_end` replay re-rendered reasoning + text
 *     that streaming had already shown.
 */

import { type Component } from "@earendil-works/pi-tui";
import { AssistantMessage } from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";

export const STREAMING_UI_FLUSH_MS = 50;

/**
 * Factory the host supplies so the controller can mount fresh components into
 * the transcript. Keeping creation in the controller lets step-boundary
 * detection (open/close step) stay fully internal.
 */
export interface StreamingComponentFactory {
  /** Mount a live-mode ThinkingComponent; return it for the controller to feed. */
  createThinking(): ThinkingComponent;
  /** Mount an empty AssistantMessage; return it for the controller to feed. */
  createText(): AssistantMessage;
  /** Append a finalized (non-streaming) component to the transcript. */
  addTranscriptChild(component: Component): void;
}

/** In-flight assistant message: at most one thinking block and one text block. */
interface CurrentStep {
  thinking: ThinkingComponent | null;
  text: AssistantMessage | null;
  thinkingText: string;
  textText: string;
  thinkingFinalized: boolean;
}

export class StreamingUIController {
  /** `null` between steps (after closeStep, before the next chunk arrives). */
  private step: CurrentStep | null = null;
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private dirty = false;
  /**
   * True once ANY stream_chunk has been appended this turn. Stays true across
   * step boundaries (closeStep does not reset it) so that the post-hoc
   * `message_end` replay can tell "streaming happened this turn, reconcile
   * only" from "non-streaming provider, build from message_end". Reset only on
   * end() (turn boundary).
   */
  private streamedThisTurn = false;

  constructor(
    private readonly requestRender: () => void,
    private readonly factory: StreamingComponentFactory,
    private readonly flushMs = STREAMING_UI_FLUSH_MS,
  ) {}

  // -- step lifecycle -----------------------------------------------------

  /**
   * True iff the current step has received any reasoning or text content.
   * Only meaningful for the *currently open* step.
   */
  get currentStepHasContent(): boolean {
    return (
      this.step !== null &&
      (this.step.thinkingText.length > 0 || this.step.textText.length > 0)
    );
  }

  /**
   * True iff ANY stream_chunk was appended this turn (across all steps). This
   * is the dedup gate for the post-hoc `message_end` replay: once streaming has
   * happened, every message_end for the turn is treated as reconciliation,
   * never as "build blocks from scratch".
   */
  get hasStreamedThisTurn(): boolean {
    return this.streamedThisTurn;
  }

  get isCurrentStepStreaming(): boolean {
    return this.step !== null;
  }

  /**
   * Close the current step: finalize a live ThinkingComponent, flush, then drop
   * the slot reference. Mounted components stay in the transcript as frozen
   * siblings. Safe to call when no step is open (no-op).
   */
  closeStep(): void {
    if (this.step === null) return;
    this.finalizeThinkingIfActive();
    this.flushNow();
    this.step = null;
  }

  /** Finalize the current step's thinking if it exists and is still live. */
  finalizeThinkingIfActive(): void {
    const s = this.step;
    if (s && s.thinking !== null && !s.thinkingFinalized) {
      s.thinking.finalize();
      s.thinkingFinalized = true;
      this.requestRender();
    }
  }

  // -- push model (stream_chunk deltas) -----------------------------------

  /**
   * Append a reasoning token. Step-boundary detection:
   *   - no open step              → open one, create a live ThinkingComponent
   *   - open step, text seen      → NEW STEP (text→reasoning is forbidden
   *                                 within one provider round-trip): close the
   *                                 current step, open a fresh one
   *   - open step, no thinking yet→ create the ThinkingComponent (first block)
   *   - otherwise                 → append to the existing block
   *
   * Provider guarantee relied on: reasoning precedes text within a single
   * model round-trip, and never reappears after text in the same round-trip.
   */
  appendReasoning(token: string): void {
    this.streamedThisTurn = true;
    if (this.step !== null && this.step.text !== null) {
      // text→reasoning transition: a new model round-trip has begun.
      this.closeStep();
    }
    if (this.step === null) {
      this.step = this.freshStep();
    }
    const s = this.step;
    if (s.thinking === null) {
      s.thinking = this.factory.createThinking();
    }
    s.thinkingText += token;
    this.dirty = true;
    this.scheduleFlush();
  }

  /**
   * Append a text token. Within one step, the first text token finalizes any
   * live thinking (reasoning→text transition); subsequent text tokens append.
   */
  appendText(token: string): void {
    this.streamedThisTurn = true;
    if (this.step === null) {
      this.step = this.freshStep();
    }
    const s = this.step;
    if (s.thinking !== null && !s.thinkingFinalized) {
      s.thinking.finalize();
      s.thinkingFinalized = true;
    }
    if (s.text === null) {
      s.text = this.factory.createText();
    }
    s.textText += token;
    this.dirty = true;
    this.scheduleFlush();
  }

  // -- component attachment (Path B: caller pre-creates finalized blocks) -

  /**
   * Attach a pre-created ThinkingComponent (e.g. finalized mode from a
   * non-streaming message_end). Opens a step if none is open.
   */
  attachThinking(comp: ThinkingComponent): void {
    if (this.step === null) this.step = this.freshStep();
    this.step.thinking = comp;
    this.step.thinkingFinalized = true;
  }

  /** Attach a pre-created AssistantMessage (non-streaming path). */
  attachText(comp: AssistantMessage): void {
    if (this.step === null) this.step = this.freshStep();
    this.step.text = comp;
  }

  // -- lifecycle ----------------------------------------------------------

  /**
   * End the turn: close any open step and clear all state. Mounted components
   * stay in the transcript; references are dropped so the next turn's
   * controller starts clean each turn.
   */
  end(): void {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.closeStep();
    this.dirty = false;
    this.streamedThisTurn = false;
  }

  // -- internal -----------------------------------------------------------

  private freshStep(): CurrentStep {
    return {
      thinking: null,
      text: null,
      thinkingText: "",
      textText: "",
      thinkingFinalized: false,
    };
  }

  private scheduleFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushNow();
    }, this.flushMs);
  }

  private flushNow(): void {
    if (!this.dirty) return;
    const s = this.step;
    if (s) {
      if (s.thinking && s.thinkingText) {
        s.thinking.updateContent(s.thinkingText);
      }
      if (s.text && s.textText) {
        s.text.updateContent(s.textText);
      }
    }
    this.dirty = false;
    this.requestRender();
  }
}
