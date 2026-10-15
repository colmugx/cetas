/**
 * answer.test.ts — the `answer_question` renderer: the durable transcript
 * record of the parent agent's reply to a parked subagent question.
 * Structured payload when live, persisted content lines on replay.
 */

import { describe, expect, it } from "bun:test";
import { parseCetasEvent } from "../events.ts";
import { SubagentActivityStore } from "../controllers/subagent-activity.ts";
import { answerQuestionRenderer } from "./answer.ts";
import type { ToolRenderContext } from "./registry.ts";

/** Full ToolRenderContext fixture — callers override what they care about. */
function makeCtx(overrides: Partial<ToolRenderContext> = {}): ToolRenderContext {
  return {
    toolCallId: "call_a",
    toolName: "answer_question",
    toolLabel: "answer_question",
    args: {},
    cwd: "/tmp/fake",
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

function renderResult(
  payload: { content: string; isError: boolean; structured?: unknown },
  ctxOverrides: Partial<ToolRenderContext> = {},
): string {
  return answerQuestionRenderer
    .renderResult!(payload, { expanded: false, isPartial: false }, makeCtx(ctxOverrides))
    .render(80)
    .join("\n");
}

function storeWithNick(): { store: SubagentActivityStore; nick: string } {
  const store = new SubagentActivityStore();
  store.apply(
    parseCetasEvent({
      type: "subagent_event",
      child_session: "sub-1",
      kind: "coder",
      parent_call: "call_1",
      ev: { type: "turn_started" },
    })!,
  );
  return { store, nick: store.get("sub-1")!.display_name };
}

describe("answerQuestionRenderer", () => {
  it("renders the call line with the question id", () => {
    const text = answerQuestionRenderer
      .renderCall!(makeCtx({ args: { question_id: "question-1" } }))
      .render(80)
      .join("\n");
    expect(text).toContain("answer");
    expect(text).toContain("question-1");
  });

  it("renders the structured select answer under the child nickname", () => {
    const { store, nick } = storeWithNick();
    const text = renderResult(
      {
        content:
          "answer accepted for question question-1 — the child continues; its final result arrives as a follow-up turn\nquestion: Which database should we use?\nanswer: postgres (index 0)",
        isError: false,
        structured: {
          question_id: "question-1",
          child_session: "sub-1",
          answered: true,
          question: "Which database should we use?",
          type: "select",
          options: ["postgres", "sqlite"],
        },
      },
      {
        args: { question_id: "question-1", index: 0 },
        subagentActivity: store,
      },
    );
    expect(text).toContain(`→ ${nick}`);
    expect(text).toContain(
      '"Which database should we use?" → postgres (index 0)',
    );
  });

  it("renders confirm answers from the call args", () => {
    const text = renderResult(
      {
        content: "answer accepted for question question-2 — the child continues",
        isError: false,
        structured: {
          question_id: "question-2",
          child_session: "sub-2",
          answered: true,
          question: "Proceed?",
          type: "confirm",
          options: null,
        },
      },
      { args: { question_id: "question-2", confirm: true } },
    );
    expect(text).toContain('"Proceed?" → true');
  });

  it("rebuilds the pair from content lines alone (replay path)", () => {
    const text = renderResult({
      content:
        "answer accepted for question question-1 — the child continues; its final result arrives as a follow-up turn\nquestion: Proceed?\nanswer: true",
      isError: false,
    });
    expect(text).toContain('"Proceed?" → true');
    expect(text).not.toContain("→ apple");
  });

  it("degrades to the fallback for legacy receipts without the pair", () => {
    const text = renderResult({
      content:
        "answer accepted for question question-1 — the child continues; its final result arrives as a follow-up turn",
      isError: false,
    });
    expect(text).toContain("answer");
    expect(text).toContain("answer accepted for question question-1");
  });

  it("error results delegate to the fallback verbatim", () => {
    const text = renderResult({
      content: "question 'question-1' is already answered",
      isError: true,
    });
    expect(text).toContain("already answered");
  });
});
