/**
 * specs.test.ts — assertion coverage for the data-driven ToolRow engine.
 *
 * Renderers are invoked directly with a minimal ToolRenderContext; pi-tui
 * `Text.render(80)` output is ANSI-stripped for plain-text substring checks
 * (style assertions compare against the same theme functions, so they hold
 * whether or not chalk is color-enabled in the test environment).
 */

import { describe, expect, test } from "bun:test";
import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  pickToolRenderer,
  registerToolRenderer,
  type ToolRenderContext,
  type ToolRenderResultPayload,
  type ToolRenderer,
} from "./registry.ts";
import { summaryOf, TOOL_ROW_SPECS } from "./specs.ts";
import { ToolRow } from "../transcript/components.ts";

const ANSI = /\x1b\[[0-9;]*m/g;

function strip(s: string): string {
  return s.replace(ANSI, "");
}

function makeCtx(overrides: Partial<ToolRenderContext> = {}): ToolRenderContext {
  return {
    toolCallId: "tc_test",
    toolName: "grep",
    toolLabel: "grep",
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

function renderCall(renderer: ToolRenderer, ctx: ToolRenderContext): string {
  const comp = renderer.renderCall?.(ctx);
  if (!comp) throw new Error("renderer has no renderCall");
  return comp.render(80).map(strip).join("\n");
}

function renderResult(
  renderer: ToolRenderer,
  result: ToolRenderResultPayload,
  ctx: ToolRenderContext,
): string {
  const comp = renderer.renderResult?.(result, { expanded: false, isPartial: false }, ctx);
  if (!comp) throw new Error("renderer has no renderResult");
  return comp.render(80).map(strip).join("\n");
}

/** First non-blank rendered line — the "line 1" of the unified invariant. */
function firstLine(rendered: string): string {
  const line = rendered.split("\n").find((l) => l.trim().length > 0);
  return line ?? "";
}

describe("spec table — call views", () => {
  test("grep call line: bullet + title + yellow pattern + muted path", () => {
    const renderer = pickToolRenderer("grep");
    const ctx = makeCtx({ toolName: "grep", args: { pattern: "needle", path: "src" } });
    const rendered = renderCall(renderer, ctx);
    expect(rendered).toContain("● grep needle  src");
    // Style: pattern goes through theme.yellow (symmetric under chalk level 0).
    expect(renderer.renderCall?.(ctx)?.render(80).join("\n")).toContain(
      theme.yellow("needle"),
    );
  });

  test("edit secondary: replace_all boolean true → (all), absent → (single)", () => {
    const renderer = pickToolRenderer("edit");
    expect(
      renderCall(renderer, makeCtx({
        toolName: "edit",
        args: { path: "a.ts", replace_all: true },
      })),
    ).toContain("● edit a.ts  (all)");
    expect(
      renderCall(renderer, makeCtx({
        toolName: "edit",
        args: { path: "a.ts", replace_all: false },
      })),
    ).toContain("● edit a.ts  (single)");
    expect(
      renderCall(renderer, makeCtx({ toolName: "edit", args: { path: "a.ts" } })),
    ).toContain("● edit a.ts  (single)");
    // String-typed replace_all must behave the same.
    expect(
      renderCall(renderer, makeCtx({
        toolName: "edit",
        args: { path: "a.ts", replace_all: "true" },
      })),
    ).toContain("● edit a.ts  (all)");
  });

  test("write secondary shows byte count; read/glob fall back to placeholder args", () => {
    expect(
      renderCall(pickToolRenderer("write"), makeCtx({
        toolName: "write",
        args: { path: "b.ts", content: "hello world" },
      })),
    ).toContain("● write b.ts  (11 bytes)");
    expect(
      renderCall(pickToolRenderer("read"), makeCtx({ toolName: "read", args: {} })),
    ).toContain("● read (no path)");
    expect(
      renderCall(pickToolRenderer("glob"), makeCtx({ toolName: "glob", args: { pattern: "*.ts" } })),
    ).toContain("● glob *.ts  .");
  });
});

describe("grep summaries — the N+1 count regression", () => {
  const MATCHES_27 =
    "Found 27 matches:\n" +
    Array.from({ length: 27 }, (_, i) => `f.txt:${i + 1}:needle\n`).join("");

  test("header 'Found 27 matches' + 27 lines renders 27 matches, never 28", () => {
    const rendered = renderResult(
      pickToolRenderer("grep"),
      { content: MATCHES_27, isError: false },
      makeCtx({ toolName: "grep", args: { pattern: "needle" } }),
    );
    expect(rendered).toContain("27 matches");
    expect(rendered).not.toContain("28");
  });

  test("zero-match content ('No matches found for: x') renders 'no matches'", () => {
    const rendered = renderResult(
      pickToolRenderer("grep"),
      { content: "No matches found for: x", isError: false },
      makeCtx({ toolName: "grep", args: { pattern: "x" } }),
    );
    expect(rendered).toContain("no matches");
  });

  test("singular header renders '1 match', plural '2 matches' (exact spelling)", () => {
    const grep = pickToolRenderer("grep");
    expect(
      renderResult(grep, { content: "Found 1 matches:\na\n", isError: false }, makeCtx()),
    ).toContain("1 match");
    expect(
      renderResult(grep, { content: "Found 2 matches:\na\nb\n", isError: false }, makeCtx()),
    ).toContain("2 matches");
    const glob = pickToolRenderer("glob");
    expect(
      renderResult(glob, { content: "Found 1 files:\na\n", isError: false }, makeCtx()),
    ).toContain("1 file");
  });
});

describe("structured summary precedence", () => {
  test("glob: structured {summary:'5 files'} wins and preview still appends", () => {
    const rendered = renderResult(
      pickToolRenderer("glob"),
      {
        content: "Found 5 files:\na.ts\nb.ts\nc.ts\nd.ts\ne.ts\n",
        isError: false,
        structured: { summary: "5 files", count: 5 },
      },
      makeCtx({ toolName: "glob", args: { pattern: "*" } }),
    );
    expect(rendered).toContain("5 files");
    expect(rendered).toContain("a.ts  b.ts  c.ts (+2 more)");
  });

  test("grep: structured summary beats a contradictory content header", () => {
    const rendered = renderResult(
      pickToolRenderer("grep"),
      {
        content: "Found 2 matches:\nx:1:a\ny:1:b\n",
        isError: false,
        structured: { summary: "9 matches", count: 9 },
      },
      makeCtx({ toolName: "grep", args: { pattern: "a" } }),
    );
    expect(rendered).toContain("9 matches");
    expect(rendered).not.toContain("2 matches");
  });

  test("summaryOf extracts only string-typed non-empty summary fields", () => {
    expect(summaryOf({ summary: "3 files" })).toBe("3 files");
    expect(summaryOf({ summary: "" })).toBeUndefined();
    expect(summaryOf({ summary: 7 })).toBeUndefined();
    expect(summaryOf({ count: 7 })).toBeUndefined();
    expect(summaryOf(null)).toBeUndefined();
    expect(summaryOf([1, 2])).toBeUndefined();
  });
});

describe("unified invariant — result line 1 = bullet + title + primary", () => {
  const cases: Array<[string, unknown, string, string]> = [
    ["read", { path: "src/a.ts" }, "first line\nsecond line", "src/a.ts"],
    ["write", { path: "src/b.ts", content: "x" }, "wrote", "src/b.ts"],
    ["edit", { path: "src/c.ts", replace_all: false }, "edited", "src/c.ts"],
    ["glob", { pattern: "*.ts", path: "src" }, "Found 2 files:\na\nb\n", "*.ts"],
    ["grep", { pattern: "needle", path: "src" }, "Found 1 matches:\na\n", "needle"],
  ];

  for (const [tool, args, content, primary] of cases) {
    test(`${tool} result line 1 contains title and ${primary}`, () => {
      const rendered = renderResult(
        pickToolRenderer(tool),
        { content, isError: false },
        makeCtx({ toolName: tool, args }),
      );
      const line1 = firstLine(rendered);
      expect(line1).toContain(tool);
      expect(line1).toContain(primary);
    });
  }

  test("every spec table entry is exercised by a renderer", () => {
    // Guards the loop above against silently dropping a spec entry.
    expect(Object.keys(TOOL_ROW_SPECS).sort()).toEqual([
      "edit",
      "glob",
      "grep",
      "read",
      "write",
    ]);
  });
});

describe("hook renderers stay intact", () => {
  test("fallback: JSON args dump + truncated result", () => {
    const renderer = pickToolRenderer("mystery_tool");
    expect(
      renderCall(renderer, makeCtx({ toolName: "mystery_tool", args: { x: 1 } })),
    ).toContain('{"x":1}');
    expect(
      renderResult(
        renderer,
        { content: "raw tool output", isError: false },
        makeCtx({ toolName: "mystery_tool", args: { x: 1 } }),
      ),
    ).toContain("raw tool output");
  });

  test("bash: '$' + command on the call line, elapsed stopped by the result", () => {
    const renderer = pickToolRenderer("bash");
    const ctx = makeCtx({ toolName: "bash", args: { cmd: "ls -la" } });
    expect(renderCall(renderer, ctx)).toContain("$ ls -la");
    // renderResult clears the elapsed timer — keep it in the same test so
    // the interval never outlives the test run.
    expect(
      renderResult(renderer, { content: "done", isError: false }, ctx),
    ).toContain("$ ls -la");
  });

  test("ask_question: question head plus option list", () => {
    const renderer = pickToolRenderer("ask_question");
    const rendered = renderCall(
      renderer,
      makeCtx({
        toolName: "ask_question",
        args: { question: "Deploy now?", options: ["yes", "no"] },
      }),
    );
    expect(rendered).toContain("ask Deploy now?");
    expect(rendered).toContain("「yes」");
    expect(rendered).toContain("「no」");
  });
});

describe("ToolRow — toolCallId and structured threading", () => {
  test("constructor populates ctx.toolCallId; setResult passes structured through", () => {
    let capturedCtx: ToolRenderContext | undefined;
    let capturedResult: ToolRenderResultPayload | undefined;
    registerToolRenderer("probe-tool", {
      renderCall(ctx) {
        capturedCtx = ctx;
        return new Text("probe call", 1, 0);
      },
      renderResult(result) {
        capturedResult = result;
        return new Text("probe result", 1, 0);
      },
    });

    const row = new ToolRow("probe-tool", "call_42", {}, "/tmp", () => {});
    expect(capturedCtx?.toolCallId).toBe("call_42");

    row.setResult("Found 3 matches:\n", false, { summary: "3 matches", count: 3 });
    expect(capturedResult?.structured).toEqual({ summary: "3 matches", count: 3 });
    expect(capturedResult?.isError).toBe(false);
  });

  test("toolLabel defaults to toolName; explicit label reaches the renderer ctx", () => {
    let seen: string | undefined;
    registerToolRenderer("label-probe", {
      renderCall(ctx) {
        seen = ctx.toolLabel;
        return new Text("probe", 1, 0);
      },
    });
    new ToolRow("label-probe", "c1", {}, "/tmp", () => {});
    expect(seen).toBe("label-probe");
    new ToolRow("label-probe", "c2", {}, "/tmp", () => {}, "nowledge-mem:memory_search");
    expect(seen).toBe("nowledge-mem:memory_search");
  });

  test("setExpanded(true) re-renders the result with expanded options", () => {
    let expandedSeen: boolean | undefined;
    registerToolRenderer("expand-probe", {
      renderCall: () => new Text("probe call", 1, 0),
      renderResult(_result, options) {
        expandedSeen = options.expanded;
        return new Text("probe result", 1, 0);
      },
    });
    const row = new ToolRow("expand-probe", "call_43", {}, "/tmp", () => {});
    row.setResult("content", false);
    expect(expandedSeen).toBe(false);
    row.setExpanded(true);
    expect(expandedSeen).toBe(true);
  });
});
