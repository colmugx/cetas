/**
 * fallback.test.ts — multi-line preview + toolLabel coverage for the
 * fallback renderer and the shared previewLines helper (W1a/W3b).
 *
 * Same harness style as specs.test.ts: renderers invoked directly, ANSI
 * stripped from `render(80)` output for plain-text substring checks.
 */

import { describe, expect, test } from "bun:test";
import {
  EXPANDED_MAX,
  previewLines,
  type ToolRenderContext,
  type ToolRenderResultPayload,
} from "./registry.ts";
import { fallbackRenderer } from "./fallback.ts";
import { bashRenderer } from "./bash.ts";
import { pickToolRenderer } from "./registry.ts";

const ANSI = /\x1b\[[0-9;]*m/g;

function strip(s: string): string {
  return s.replace(ANSI, "");
}

function makeCtx(overrides: Partial<ToolRenderContext> = {}): ToolRenderContext {
  return {
    toolCallId: "tc_fallback",
    toolName: "memory_search",
    toolLabel: "nowledge-mem:memory_search",
    args: { q: "ports" },
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

function renderResult(
  result: ToolRenderResultPayload,
  ctx: ToolRenderContext = makeCtx(),
  expanded = false,
): string[] {
  const comp = fallbackRenderer.renderResult?.(
    result,
    { expanded, isPartial: false },
    ctx,
  );
  if (!comp) throw new Error("fallback renderer has no renderResult");
  return comp.render(80).map((l) => strip(l).trim());
}

describe("previewLines", () => {
  test("keeps newlines, takes 3 lines, appends (+N lines) tail", () => {
    expect(previewLines("l1\nl2\nl3\nl4\nl5")).toBe("l1\nl2\nl3\n… (+2 lines)");
  });

  test("no tail when within maxLines; maxLines is adjustable", () => {
    expect(previewLines("a\nb\nc")).toBe("a\nb\nc");
    expect(previewLines("a\nb\nc\nd", 2)).toBe("a\nb\n… (+2 lines)");
  });

  test("pretty-prints JSON payloads (nmem --json stdout)", () => {
    const out = previewLines('{"memories":[{"id":"a","title":"t"}]}');
    expect(out).toBe('{\n  "memories": [\n    {\n… (+5 lines)');
  });

  test("brace-led non-JSON falls back to the raw text", () => {
    expect(previewLines("{oops\nline2")).toBe("{oops\nline2");
  });

  test("EXPANDED_MAX caps at 50 lines with a tail", () => {
    const content = Array.from({ length: 60 }, (_, i) => `x${i}`).join("\n");
    const out = previewLines(content, EXPANDED_MAX);
    expect(out.split("\n")).toHaveLength(51);
    expect(out.endsWith("… (+10 lines)")).toBeTrue();
  });
});

describe("fallback renderer — result views", () => {
  test("title line: bullet + toolLabel; body is a 3-line preview with tail", () => {
    const lines = renderResult({ content: "r1\nr2\nr3\nr4", isError: false });
    expect(lines[0]).toContain("● nowledge-mem:memory_search");
    expect(lines.slice(1)).toEqual(["r1", "r2", "r3", "… (+1 lines)"]);
  });

  test("structured.summary wins over content preview", () => {
    const lines = renderResult({
      content: "r1\nr2\nr3\nr4",
      isError: false,
      structured: { summary: "added 1 memory" },
    });
    expect(lines).toContain("added 1 memory");
    expect(lines).not.toContain("r1");
  });

  test("error results use the same title + multiline body", () => {
    const lines = renderResult(
      { content: "boom line1\nboom line2", isError: true },
      makeCtx({ isError: true }),
    );
    expect(lines[0]).toContain("● nowledge-mem:memory_search");
    expect(lines).toContain("boom line2");
  });

  test("expanded widens the preview up to EXPANDED_MAX", () => {
    const content = Array.from({ length: 10 }, (_, i) => `line${i + 1}`).join("\n");
    const collapsed = renderResult({ content, isError: false });
    expect(collapsed.filter((l) => l.length > 0)).toHaveLength(5); // title + 3 + tail
    expect(collapsed).toContain("… (+7 lines)");

    const expanded = renderResult({ content, isError: false }, makeCtx(), true);
    expect(expanded.filter((l) => l.length > 0)).toHaveLength(11); // title + 10
    expect(expanded).toContain("line10");
    expect(EXPANDED_MAX).toBeGreaterThan(10);
  });

  test("renderCall titles with toolLabel too", () => {
    const comp = fallbackRenderer.renderCall?.(makeCtx());
    const rendered = comp?.render(80).map((l) => strip(l)).join("\n") ?? "";
    expect(rendered).toContain("nowledge-mem:memory_search");
    expect(rendered).toContain('{"q":"ports"}');
  });
});

describe("expanded flag reaches the other renderers", () => {
  test("bash: full multiline stdout when expanded, first line when not", () => {
    const ctx = makeCtx({ toolName: "bash", toolLabel: "bash", args: { cmd: "ls" } });
    const result: ToolRenderResultPayload = { content: "a\nb\nc\nd", isError: false };
    const collapsed = bashRenderer.renderResult?.(
      result,
      { expanded: false, isPartial: false },
      ctx,
    )?.render(80).map((l) => strip(l).trim()) ?? [];
    expect(collapsed).not.toContain("b");

    const expanded = bashRenderer.renderResult?.(
      result,
      { expanded: true, isPartial: false },
      ctx,
    )?.render(80).map((l) => strip(l).trim()) ?? [];
    expect(expanded).toContain("d");
  });

  test("spec renderer (write, no summarize): content fallback goes multiline", () => {
    const renderer = pickToolRenderer("write");
    const ctx = makeCtx({ toolName: "write", toolLabel: "write", args: { path: "p" } });
    const result: ToolRenderResultPayload = { content: "w1\nw2\nw3\nw4", isError: false };

    const collapsed = renderer.renderResult?.(
      result,
      { expanded: false, isPartial: false },
      ctx,
    )?.render(80).map((l) => strip(l).trim()).join("\n") ?? "";
    expect(collapsed).toContain("w1 w2 w3 w4"); // truncateForPreview flattens

    const expanded = renderer.renderResult?.(
      result,
      { expanded: true, isPartial: false },
      ctx,
    )?.render(80).map((l) => strip(l).trim()) ?? [];
    expect(expanded).toContain("w1"); // newlines survive expansion
    expect(expanded).toContain("w4");
  });
});
