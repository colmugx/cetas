/**
 * components.ts — transcript-row components built from CetasEvents.
 *
 * The transcript is a flat list of rows. Each row is one of:
 *   - UserMessage         — user's prompt (echo)
 *   - AssistantMessage    — finalized assistant reply (Markdown)
 *   - ToolRow             — a tool call + (later) its result
 *   - SystemNotice        — turn_started/failed/deferred/etc.
 *
 * We don't try to nest tool rows inside AssistantMessage: posoco emits them
 * as separate events in time order, so flattening matches the wire model.
 */

import {
  Box,
  Container,
  Markdown,
  Spacer,
  Text,
  type Component,
} from "@earendil-works/pi-tui";
import { theme, markdownTheme } from "../../ui/theme.ts";
import { wrapAssistantLines, wrapUserLines } from "../../ui/osc133.ts";
import {
  pickToolRenderer,
  statusBullet,
  type ToolRenderContext,
} from "../tool-renderers/index.ts";
import type { BridgeMessage } from "../events.ts";

/**
 * User prompt echo.
 *
 * Block layout: a leading `Spacer(1)` separates it from whatever came
 * before, then the text sits inside a full-width tinted `Box` (userMessageBg,
 * #343541). The Box gives the user turn a distinct visual zone so the next
 * query never visually merges with the previous answer. OSC 133 wraps the
 * whole block so terminal scrollback sees the prompt boundary.
 */
export class UserMessage extends Container {
  constructor(text: string) {
    super();
    this.addChild(new Spacer(1));
    const box = new Box(1, 0, (s) => theme.userMessageBg(s));
    box.addChild(new Text(theme.user("> ") + text, 0, 0));
    this.addChild(box);
  }
  override render(width: number): string[] {
    return wrapUserLines(super.render(width));
  }
}

/**
 * User prompt queued as a follow-up on the running turn. Rendered dim with a
 * "queued" marker; `promote()` restyles it in place once the Agent drains it
 * at a turn boundary (each drained turn starts with a TurnStarted event).
 */
export class QueuedUserMessage extends Container {
  private promoted = false;

  constructor(private readonly prompt: string) {
    super();
    this.addChild(new Spacer(1));
    const box = new Box(1, 0, (s) => theme.userMessageBg(s));
    box.addChild(new Text(theme.muted(`> ${prompt} · queued`), 0, 0));
    this.addChild(box);
  }

  promote(): void {
    if (this.promoted) return;
    this.promoted = true;
    while (this.children.length > 1) {
      this.children.pop();
    }
    const box = new Box(1, 0, (s) => theme.userMessageBg(s));
    box.addChild(new Text(theme.user("> ") + this.prompt, 0, 0));
    this.addChild(box);
    this.invalidate();
  }

  override render(width: number): string[] {
    return wrapUserLines(super.render(width));
  }
}

/**
 * Finalized assistant message. Uses Markdown for rich formatting.
 *
 * Leading `Spacer(1)` separates it from the preceding block (user prompt,
 * tool row, etc.). The message itself is transparent (no background) so the
 * answer reads cleanly; the surrounding whitespace is the only separator.
 * `updateContent()` lets the streaming controller reuse the same instance
 * as deltas arrive — cheap diffing is pi-tui's job.
 */
export class AssistantMessage extends Container {
  private md: Markdown;
  private reasoningText?: Text;
  private text: string;

  constructor(initialText = "") {
    super();
    this.text = initialText;
    // Spacer is child[0]; the markdown is appended after. setReasoning()
    // inserts between them by removeChild(md) + addChild(reasoning) +
    // addChild(md), which preserves the leading spacer.
    this.addChild(new Spacer(1));
    this.md = new Markdown(initialText, 1, 0, markdownTheme);
    this.addChild(this.md);
  }

  updateContent(text: string): void {
    this.text = text;
    this.md.setText(text);
    this.invalidate();
  }

  /** Show reasoning above the markdown — optional. */
  setReasoning(reasoning: string): void {
    const trimmed = reasoning.trim();
    if (trimmed === "") {
      if (this.reasoningText) {
        this.removeChild(this.reasoningText);
        this.reasoningText = undefined;
      }
      return;
    }
    const line = theme.italic(theme.muted(`💭 ${trimmed.split("\n")[0]}`));
    if (this.reasoningText) {
      this.reasoningText.setText(line);
    } else {
      this.reasoningText = new Text(line, 1, 0);
      // Insert at top, before markdown.
      this.removeChild(this.md);
      this.addChild(this.reasoningText);
      this.addChild(this.md);
    }
    this.invalidate();
  }

  override render(width: number): string[] {
    return wrapAssistantLines(super.render(width));
  }
}

/**
 * A single tool-call row. Owns its renderer context and renders
 * call/result via the registered ToolRenderer.
 */
export class ToolRow extends Container {
  private ctx: ToolRenderContext;
  private renderer = pickToolRenderer("fallback"); // set in constructor
  private result?: { content: string; isError: boolean; structured?: unknown };
  private finished = false;

  constructor(
    private readonly toolName: string,
    toolCallId: string,
    args: unknown,
    cwd: string,
    invalidateParent: () => void,
  ) {
    super();
    this.renderer = pickToolRenderer(toolName);
    this.ctx = {
      toolCallId,
      toolName,
      args,
      cwd,
      state: {},
      executionStarted: true,
      argsComplete: true,
      isPartial: false,
      isError: false,
      invalidate: () => {
        this.rebuild();
        invalidateParent();
      },
    };
    this.addChild(new Spacer(1));
    this.rebuild();
  }

  /** Apply a result; rebuilds the row with the success/error background. */
  setResult(content: string, isError: boolean, structured?: unknown): void {
    this.result = { content, isError, structured };
    this.finished = true;
    this.ctx.isError = isError;
    this.rebuild();
  }

  private rebuild(): void {
    // Keep the leading Spacer (index 0) — drop everything after.
    while (this.children.length > 1) {
      this.children.pop();
    }
    let comp: Component;
    if (this.finished && this.result) {
      comp = this.renderer.renderResult?.(
        this.result,
        { expanded: false, isPartial: false },
        this.ctx,
      ) ?? new Text(`  ${this.result.content.slice(0, 200)}`, 1, 0);
    } else {
      comp = this.renderer.renderCall?.(this.ctx) ??
        new Text(`${statusBullet("running")} ${this.toolName}`, 1, 0);
    }
    this.addChild(comp);
    this.invalidate();
  }
}

/**
 * System notices: turn_started, turn_failed, session_redirect, etc.
 * Single line, muted style, with a leading Spacer so it sits as its own
 * block rather than merging with the line above.
 */
export function systemNotice(text: string): Container {
  const c = new Container();
  c.addChild(new Spacer(1));
  c.addChild(new Text(theme.muted(text), 1, 0));
  return c;
}

/** Error notice (turn_failed). */
export function errorNotice(text: string): Container {
  const c = new Container();
  c.addChild(new Spacer(1));
  c.addChild(new Text(theme.error("● ") + text, 1, 0));
  return c;
}

/**
 * Build a transcript row from a finalized BridgeMessage.
 * Returns an AssistantMessage pre-populated with text + optional reasoning.
 */
export function assistantRowFromMessage(msg: BridgeMessage): AssistantMessage {
  const text = msg.content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("\n\n");
  const row = new AssistantMessage(text);
  if (msg.reasoning) row.setReasoning(msg.reasoning);
  return row;
}
