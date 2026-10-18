import { describe, expect, test } from "bun:test";
import { stripTerminalSequences } from "@earendil-works/pi-tui";

import { notifyUserRenderer } from "./notifyuser.ts";
import type { ToolRenderContext, ToolRenderResultPayload } from "./registry.ts";

function context(args: unknown): ToolRenderContext {
  return {
    toolCallId: "call-1",
    toolName: "notify_user",
    toolLabel: "notify_user",
    args,
    cwd: "/w",
    state: {},
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    isError: false,
    expanded: false,
    invalidate() {},
  };
}

const call = {
  question: "Upgrade node to 22?",
  type: "confirm",
};

describe("notify_user renderer", () => {
  test("the call view leads with the question and the kind", () => {
    const text = stripTerminalSequences(
      notifyUserRenderer.renderCall!(context(call)).render(120).join("\n"),
    );
    expect(text).toContain("asks");
    expect(text).toContain("Upgrade node to 22?");
    expect(text).toContain("[confirm]");
  });

  test("select questions list their options", () => {
    const text = stripTerminalSequences(
      notifyUserRenderer
        .renderCall!(context({ question: "Pick", type: "select", options: ["A", "B"] }))
        .render(120)
        .join("\n"),
    );
    expect(text).toContain("A");
    expect(text).toContain("B");
  });

  test("the result view says submitted, never answered", () => {
    const result: ToolRenderResultPayload = {
      content: "question submitted; the turn continues...\nquestion_id: question-3\nshort_id: @q3",
      isError: false,
      structured: { status: "submitted", question_id: "question-3", short_id: "@q3" },
    };
    const text = stripTerminalSequences(
      notifyUserRenderer.renderResult!(result, { expanded: false, isPartial: false }, context(call))
        .render(120)
        .join("\n"),
    );
    expect(text).toContain("submitted");
    expect(text).toContain("@q3");
    expect(text.toLowerCase()).not.toContain("answered");
  });

  test("replay without structured payload still finds the short id", () => {
    const result: ToolRenderResultPayload = {
      content: "question submitted...\nquestion_id: question-3\nshort_id: @q3",
      isError: false,
    };
    const text = stripTerminalSequences(
      notifyUserRenderer.renderResult!(result, { expanded: false, isPartial: false }, context(call))
        .render(120)
        .join("\n"),
    );
    expect(text).toContain("@q3");
  });

  test("errors fall back to the content with an error bullet", () => {
    const result: ToolRenderResultPayload = { content: "boom", isError: true };
    const text = stripTerminalSequences(
      notifyUserRenderer.renderResult!(result, { expanded: false, isPartial: false }, context(call))
        .render(120)
        .join("\n"),
    );
    expect(text).toContain("boom");
  });
});
