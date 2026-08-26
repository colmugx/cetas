/**
 * thinking.ts — ThinkingComponent for live / finalized reasoning display.
 *
 * Two modes:
 *   - live: braille spinner + "thinking..." + last 3 lines of content
 *   - finalized: "💭 thought · N lines · ctrl+t …" header + collapsed
 *     3-line preview (ctrl+t toggles full content)
 *
 * Live mode is for streaming reasoning tokens (stream_chunk kind="reasoning").
 * Finalized mode is for non-streaming message_end or after thinking is done.
 *
 * A leading `Spacer(1)` separates the thinking block from the preceding
 * block (user prompt, previous answer, etc.) — each transcript block owns
 * its own leading whitespace.
 */

import { Container, Spacer, Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import { previewLines } from "../tool-renderers/registry.ts";

type ThinkingMode = "live" | "finalized";

const BRAILLE_FRAMES = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"];
const SPINNER_MS = 80;
const PREVIEW_LINES = 3;

export class ThinkingComponent extends Container {
  private mode: ThinkingMode;
  private contentText: string;
  private headerEl: Text;
  private bodyEl: Text;
  /** Finalized-mode only: show the 3-line preview (true) or full content. */
  private collapsed = true;
  private spinnerIndex = 0;
  private spinnerTimer: ReturnType<typeof setInterval> | null = null;

  constructor(initialText = "", initialMode: ThinkingMode = "live") {
    super();
    this.mode = initialMode;
    this.contentText = initialText;

    this.headerEl = new Text("", 1, 0);
    this.bodyEl = new Text("", 1, 0);
    // Spacer is child[0]; header/body follow so the block breathes.
    this.addChild(new Spacer(1));
    this.addChild(this.headerEl);
    this.addChild(this.bodyEl);

    if (this.mode === "live") {
      this.startSpinner();
    }
    this.renderContent();
  }

  /** Push new thinking content (replaces, not appends — caller accumulates). */
  updateContent(text: string): void {
    this.contentText = text;
    this.renderContent();
    this.invalidate();
  }

  /** Finalize: stop spinner, switch to static display. */
  finalize(): void {
    if (this.mode === "finalized") return;
    this.mode = "finalized";
    this.stopSpinner();
    this.renderContent();
    this.invalidate();
  }

  private startSpinner(): void {
    if (this.spinnerTimer) return;
    this.spinnerTimer = setInterval(() => {
      this.spinnerIndex = (this.spinnerIndex + 1) % BRAILLE_FRAMES.length;
      this.headerEl.setText(this.buildHeader());
      this.invalidate();
    }, SPINNER_MS);
  }

  private stopSpinner(): void {
    if (this.spinnerTimer) {
      clearInterval(this.spinnerTimer);
      this.spinnerTimer = null;
    }
  }

  private renderContent(): void {
    this.headerEl.setText(this.buildHeader());
    this.bodyEl.setText(this.buildBody());
  }

  /** ctrl+t target: collapse/expand the finalized block. */
  setCollapsed(v: boolean): void {
    if (this.collapsed === v) return;
    this.collapsed = v;
    this.renderContent();
    this.invalidate();
  }

  toggleCollapsed(): void {
    this.setCollapsed(!this.collapsed);
  }

  private buildHeader(): string {
    if (this.mode === "live") {
      const frame = BRAILLE_FRAMES[this.spinnerIndex];
      return theme.thinking(`${frame} thinking...`);
    }
    const lines = this.contentText.split("\n").length;
    const hint = this.collapsed ? "ctrl+t 展开" : "ctrl+t 收起";
    return theme.thinking(`💭 thought · ${lines} lines · ${hint}`);
  }

  private buildBody(): string {
    if (!this.contentText) return "";
    if (this.mode === "live") {
      // Show only the last PREVIEW_LINES in live mode
      const lines = this.contentText.split("\n");
      const preview = lines.slice(-PREVIEW_LINES).join("\n");
      return theme.thinking(preview);
    }
    // Finalized: collapsed keeps the first PREVIEW_LINES with a tail count.
    if (this.collapsed) {
      return theme.thinking(previewLines(this.contentText, PREVIEW_LINES));
    }
    return theme.thinking(this.contentText);
  }

  /** Clean up timer when component is discarded. */
  dispose(): void {
    this.stopSpinner();
  }
}
