/**
 * primitives.ts — thin wrappers over pi-tui components that inject the
 * cetas-js theme by default.
 *
 * Rationale: callers should not need to remember `theme.fg(...)` everywhere.
 * `UserText("hi")` is shorter than `new Text(theme.user("> ") + "hi", 1, 0)`
 * and self-documenting. When a caller needs raw behaviour, they import the
 * pi-tui primitive directly.
 */

import { Box, Container, Spacer, Text, type Component } from "@earendil-works/pi-tui";
import { theme } from "./theme.ts";
import { wrapAssistantLines, wrapUserLines } from "./osc133.ts";

/** Plain labelled text block. */
export class Txt extends Text {
  constructor(text: string, paddingX = 1, paddingY = 0) {
    super(text, paddingX, paddingY);
  }
}

/** A user-prompt echo: `> <text>` with OSC 133 wrapping. */
export class UserEcho extends Container {
  private inner: Text;
  constructor(prompt: string) {
    super();
    this.inner = new Text(theme.user("> ") + prompt, 1, 0);
    this.addChild(this.inner);
  }
  override render(width: number): string[] {
    return wrapUserLines(super.render(width));
  }
}

/** Assistant text, treated as command output for OSC 133. */
export class AssistantReply extends Container {
  constructor(text: string) {
    super();
    this.addChild(new Text(text, 1, 0));
  }
  override render(width: number): string[] {
    return wrapAssistantLines(super.render(width));
  }
}

/** Error text, single line. */
export function errorText(msg: string): Text {
  return new Text(theme.error("✗ ") + msg, 1, 0);
}

/** Info text, single line. */
export function infoText(msg: string): Text {
  return new Text(theme.info("ℹ ") + msg, 1, 0);
}

/** Soft spacer (one blank line) — shorthand used in several layouts. */
export function blankLine(): Spacer {
  return new Spacer(1);
}

/** Box with the "pending tool" background — for tool-call rows. */
export function pendingToolBox(): Box {
  return new Box(1, 0, theme.toolPendingBg);
}

/** Box with the "tool error" background. */
export function errorToolBox(): Box {
  return new Box(1, 0, theme.toolErrorBg);
}

/** Box with the "tool success" background. */
export function successToolBox(): Box {
  return new Box(1, 0, theme.toolSuccessBg);
}

/** Single-line banner used at the top of transcript / on /help. */
export function banner(title: string, subtitle?: string): Component[] {
  const lines: Component[] = [
    new Text(theme.brandBold(title), 1, 0),
  ];
  if (subtitle) {
    lines.push(new Text(theme.muted(subtitle), 1, 0));
  }
  lines.push(blankLine());
  return lines;
}
