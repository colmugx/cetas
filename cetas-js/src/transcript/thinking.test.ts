/**
 * thinking.test.ts — collapsed/finalized behavior of ThinkingComponent
 * (W3a): header carries "N lines" + the ctrl+t hint, the body stays a
 * 3-line preview until toggled, and live mode is unaffected.
 */

import { describe, expect, test } from "bun:test";
import { ThinkingComponent } from "./thinking.ts";
import { AssistantMessage } from "./components.ts";

const ANSI = /\x1b\[[0-9;]*m/g;

function renderedLines(comp: { render(width: number): string[] }): string[] {
  return comp.render(80).map((l) => l.replace(ANSI, "").trim()).filter((l) => l !== "");
}

describe("ThinkingComponent — finalized collapse", () => {
  test("header shows N lines + expand hint; body is first 3 lines + tail", () => {
    const comp = new ThinkingComponent("l1\nl2\nl3\nl4", "finalized");
    const lines = renderedLines(comp);
    expect(lines).toContain("💭 thought · 4 lines · ctrl+t 展开");
    expect(lines.slice(1)).toEqual(["l1", "l2", "l3", "… (+1 lines)"]);
  });

  test("toggle expands to full content with the collapse hint", () => {
    const comp = new ThinkingComponent("l1\nl2\nl3\nl4", "finalized");
    comp.toggleCollapsed();
    const lines = renderedLines(comp);
    expect(lines).toContain("💭 thought · 4 lines · ctrl+t 收起");
    expect(lines).toContain("l4");
    expect(lines).not.toContain("(+1 lines)");
  });

  test("setCollapsed is idempotent and re-collapses", () => {
    const comp = new ThinkingComponent("l1\nl2\nl3\nl4", "finalized");
    comp.setCollapsed(false);
    comp.setCollapsed(true);
    expect(renderedLines(comp)).not.toContain("l4");
  });

  test("live mode keeps the last-3 preview regardless of collapsed", () => {
    const comp = new ThinkingComponent("a\nb\nc\nd\ne", "live");
    const before = renderedLines(comp);
    expect(before.join("\n")).toContain("thinking...");
    expect(before).toContain("e");
    expect(before).not.toContain("a");
    comp.toggleCollapsed();
    const after = renderedLines(comp);
    expect(after).not.toContain("a");
    expect(after).toContain("e");
    comp.dispose(); // stop the spinner timer
  });
});

describe("AssistantMessage.setReasoning — collapsed-header consistency", () => {
  test("reasoning renders as '💭 thought · N lines' with no body", () => {
    const msg = new AssistantMessage("answer");
    msg.setReasoning("r1\nr2");
    const lines = renderedLines(msg);
    expect(lines).toContain("💭 thought · 2 lines");
    expect(lines).not.toContain("r1");
  });
});
