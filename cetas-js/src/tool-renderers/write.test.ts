/**
 * write.test.ts — the `write` renderer's two faces.
 *
 *   - streaming (argsComplete false): live header + last 3 tail lines of
 *     the partially-unescaped content arg;
 *   - finalized (argsComplete true / results): delegates to
 *     specRenderer(writeSpec), so output must be byte-identical to the old
 *     declarative table entry (guard against drift).
 */

import { describe, expect, test } from "bun:test";
// Registration side effects so pickToolRenderer("write") hits the hook.
import "./index.ts";
import { pickToolRenderer, type ToolRenderContext } from "./registry.ts";
import { specRenderer } from "./registry.ts";
import { writeSpec } from "./specs.ts";
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

  test("no content parsed yet: bare placeholder head, no body", () => {
    const out = renderCall(
      writeRenderer,
      makeCtx({ argsComplete: false, isPartial: true, args: {} }),
    );
    expect(out).toBe("● write …");
  });

  test("path alone shows without a line-count suffix", () => {
    const out = renderCall(
      writeRenderer,
      makeCtx({ argsComplete: false, isPartial: true, args: { path: "a.md" } }),
    );
    expect(out).toBe("● write a.md");
  });
});

describe("write renderer — finalized views are spec-identical", () => {
  const ARGS = { path: "src/b.ts", content: "hello world" };
  const RESULT = {
    content: "wrote src/b.ts",
    isError: false,
    structured: undefined as unknown,
  };
  const spec = specRenderer(writeSpec);

  test("renderCall(argsComplete) === specRenderer(writeSpec).renderCall", () => {
    const hooked = writeRenderer.renderCall?.(makeCtx({ args: ARGS }));
    const declared = spec.renderCall?.(makeCtx({ args: ARGS }));
    expect(hooked?.render(80)).toEqual(declared?.render(80));
    // And matches the historical table shape.
    expect(renderCall(writeRenderer, makeCtx({ args: ARGS }))).toContain(
      "● write src/b.ts  (11 bytes)",
    );
  });

  test("renderResult === specRenderer(writeSpec).renderResult", () => {
    const ctx = makeCtx({ args: ARGS });
    expect(
      writeRenderer.renderResult?.(RESULT, { expanded: false, isPartial: false }, ctx)
        ?.render(80),
    ).toEqual(
      spec.renderResult?.(RESULT, { expanded: false, isPartial: false }, ctx)?.render(80),
    );
    // Expanded passes through identically too.
    expect(
      writeRenderer.renderResult?.(RESULT, { expanded: true, isPartial: false }, ctx)
        ?.render(80),
    ).toEqual(
      spec.renderResult?.(RESULT, { expanded: true, isPartial: false }, ctx)?.render(80),
    );
  });

  test("pickToolRenderer dispatches write to the registered hook", () => {
    expect(pickToolRenderer("write")).toBe(writeRenderer);
    // Other spec tools stay on the generic engine.
    expect(pickToolRenderer("read")).not.toBe(writeRenderer);
  });
});
