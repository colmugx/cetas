/**
 * streaming-ui.ts — dual-track (thinking + text) accumulator with throttled
 * rendering for streaming assistant output.
 *
 * Key design change from previous version:
 *   - Components are NEVER destroyed or removed on end/abort. They are
 *     created once by the EventRouter, attached here via attach*(), and
 *     stay in the transcript permanently.
 *   - Two independent tracks: thinking (ThinkingComponent) and text
 *     (AssistantMessage). Either may be absent (non-streaming provider,
 *     no-reasoning model, etc.).
 *   - The throttled flush (STREAMING_UI_FLUSH_MS) avoids flooding pi-tui's
 *     diff loop on token-by-token pushes.
 */

import { AssistantMessage } from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";

export const STREAMING_UI_FLUSH_MS = 50;

export class StreamingUIController {
  private _thinkingComponent: ThinkingComponent | null = null;
  private _textComponent: AssistantMessage | null = null;
  private _accumulatedThinking = "";
  private _accumulatedText = "";
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private dirty = false;
  private _thinkingFinalized = false;

  constructor(
    private readonly requestRender: () => void,
    private readonly flushMs = STREAMING_UI_FLUSH_MS,
  ) {}

  // -- component attachment (called by EventRouter when first token arrives)

  /** Attach a ThinkingComponent for live reasoning updates. */
  attachThinking(comp: ThinkingComponent): void {
    this._thinkingComponent = comp;
    this._accumulatedThinking = "";
    this._thinkingFinalized = false;
  }

  /** Attach an AssistantMessage for live text updates. */
  attachText(comp: AssistantMessage): void {
    this._textComponent = comp;
    this._accumulatedText = "";
  }

  // -- push model (stream_chunk deltas — append)

  /** Append a reasoning token (stream_chunk kind="reasoning"). */
  appendReasoning(token: string): void {
    this._accumulatedThinking += token;
    this.dirty = true;
    this.scheduleFlush();
  }

  /** Append a text token (stream_chunk kind="text"). */
  appendText(token: string): void {
    this._accumulatedText += token;
    this.dirty = true;
    this.scheduleFlush();
  }

  // -- set model (message_end full content — replace)

  /**
   * Replace accumulated thinking with full content from message_end.
   * Used in non-streaming fallback path.
   */
  setFullThinking(text: string): void {
    this._accumulatedThinking = text;
    this.dirty = true;
    this.flushNow();
  }

  /**
   * Replace accumulated text with full content from message_end.
   * Used in non-streaming fallback path.
   */
  setFullText(text: string): void {
    this._accumulatedText = text;
    this.dirty = true;
    this.flushNow();
  }

  // -- lifecycle

  /**
   * Finalize thinking: switch the component from live to finalized mode.
   * No more thinking updates after this call.
   */
  finalizeThinking(): void {
    this.flushNow();
    if (this._thinkingComponent) {
      this._thinkingComponent.finalize();
    }
    this._thinkingFinalized = true;
  }

  /**
   * End streaming: flush pending content and return accumulated strings.
   *
   * Components stay mounted in the transcript (frozen via pi-tui's render
   * cache), BUT we DROP our references to them. This is the fix for the
   * "second turn overwrites first answer" bug: the next turn's
   * StreamingUIController must start with null references so it creates fresh
   * components. Mirrors pi's `streamingComponent = undefined` on message_end
   * and kimi-code's `_streamingBlock = null`.
   */
  end(): { text: string; thinking: string } {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.flushNow();
    const result = {
      text: this._accumulatedText,
      thinking: this._accumulatedThinking,
    };
    this._accumulatedText = "";
    this._accumulatedThinking = "";
    // Drop component references — they remain in the transcript as frozen
    // children, but we no longer mutate them. A new turn's controller starts
    // clean and will allocate new components.
    this._textComponent = null;
    this._thinkingComponent = null;
    this._thinkingFinalized = false;
    this.dirty = false;
    return result;
  }

  /**
   * Abort: clear accumulators and stop timer. Components stay in transcript.
   */
  abort(): void {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this._accumulatedText = "";
    this._accumulatedThinking = "";
    this.dirty = false;
  }

  // -- query

  get hasThinking(): boolean {
    return this._thinkingComponent !== null;
  }

  get hasText(): boolean {
    return this._textComponent !== null;
  }

  get isThinkingFinalized(): boolean {
    return this._thinkingFinalized;
  }

  // -- internal

  private scheduleFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushNow();
    }, this.flushMs);
  }

  private flushNow(): void {
    if (!this.dirty) return;
    if (this._thinkingComponent && this._accumulatedThinking) {
      this._thinkingComponent.updateContent(this._accumulatedThinking);
    }
    if (this._textComponent && this._accumulatedText) {
      this._textComponent.updateContent(this._accumulatedText);
    }
    this.dirty = false;
    this.requestRender();
  }
}
