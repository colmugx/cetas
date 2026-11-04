/**
 * write.test.ts — the `write` renderer's two faces.
 *
 *   - streaming (argsComplete false): live header + last 3 tail lines of
 *     the partially-unescaped content arg;
 *   - finalized (argsComplete true / results): delegates to
 *     specRenderer(writeSpec).
 */

import { describe, expect, test } from "bun:test";
// Registration side effects so pickToolRenderer("write") hits the hook.
import "./index.ts";
import { pickToolRenderer, type ToolRenderContext } from "./registry.ts";
import { writeRenderer } from "./write.ts";

const ANSI = /\x1b\[[0-9;]*m/g;

function strip(s: string): string {
  return s.replace(ANSI, "");
}

function makeCtx(overrides: Partial<ToolRenderContext> = {}): ToolRenderContext {
  return {
    toolCallId: "tc_write",
    toolName: "write",
    toolLabel: "write",
    args: {},
    cwd: "/tmp",
    state: {},
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    isError: false,
    expanded: false,
    invalidate: () => {},
    ...overrides,
  };
}

function renderCall(renderer = writeRenderer, ctx = makeCtx()): string {
  const comp = renderer.renderCall?.(ctx);
  if (!comp) throw new Error("renderer has no renderCall");
  // pi-tui pads physical lines (left pad + width); trim both ends.
  return comp.render(80).map((l) => strip(l).trim()).join("\n");
}

describe("write renderer — streaming view", () => {
  const PARTIAL_ARGS = {
    path: "notes/todo.md",
    content: "l1\nl2\nl3\nl4\nl5",
  };

  test("header shows bullet + title + path + line count", () => {
    const out = renderCall(
      writeRenderer,
      makeCtx({ argsComplete: false, isPartial: true, args: PARTIAL_ARGS }),
    );
    expect(out.split("\n")[0]).toBe("● write notes/todo.md  · 5 lines");
  });

  test("body shows only the LAST 3 lines of partial content", () => {
    const out = renderCall(
      writeRenderer,
      makeCtx({ argsComplete: false, isPartial: true, args: PARTIAL_ARGS }),
    );
    expect(out).toContain("l3\nl4\nl5");
    expect(out).not.toContain("l1");
    expect(out).not.toContain("l2");
  });
});

describe("write renderer — registered hook", () => {
  test("pickToolRenderer dispatches write to the registered hook", () => {
    expect(pickToolRenderer("write")).toBe(writeRenderer);
    // Other spec tools stay on the generic engine.
    expect(pickToolRenderer("read")).not.toBe(writeRenderer);
  });
});
