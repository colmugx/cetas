import { describe, expect, test } from "bun:test";

import { parseCetasEvent } from "./events.ts";

describe("parseCetasEvent", () => {
  test("rejects a malformed known event instead of coercing fields", () => {
    expect(() =>
      parseCetasEvent({
        type: "tool_call_completed",
        tool_call_id: 7,
        result: null,
        is_error: "false",
      })
    ).toThrow("tool_call_completed.tool_call_id must be a string");
  });

  test("rejects a non-record structured payload", () => {
    expect(() =>
      parseCetasEvent({
        type: "tool_call_completed",
        tool_call_id: "tc1",
        result: "ok",
        is_error: false,
        structured: 42,
      }),
    ).toThrow("tool_call_completed.structured must be an object");
  });

  test("rejects an invalid stream kind instead of treating it as text", () => {
    expect(() =>
      parseCetasEvent({
        type: "stream_chunk",
        raw: "",
      })
    ).toThrow("stream_chunk.kind must be text or reasoning");
  });

  describe("tool_args_delta", () => {
    test("absent and null optional fields both parse to absent", () => {
      expect(parseCetasEvent({ type: "tool_args_delta", index: 0 })).toEqual({
        type: "tool_args_delta",
        index: 0,
      });
      expect(
        parseCetasEvent({
          type: "tool_args_delta",
          index: 0,
          id: null,
          name: null,
          delta: null,
        }),
      ).toEqual({ type: "tool_args_delta", index: 0 });
    });

    test("rejects a missing / non-integer / negative index", () => {
      expect(() => parseCetasEvent({ type: "tool_args_delta" })).toThrow(
        "tool_args_delta.index must be a non-negative integer",
      );
      expect(() =>
        parseCetasEvent({ type: "tool_args_delta", index: 1.5 }),
      ).toThrow("tool_args_delta.index must be a non-negative integer");
      expect(() =>
        parseCetasEvent({ type: "tool_args_delta", index: -1 }),
      ).toThrow("tool_args_delta.index must be a non-negative integer");
    });

    test("rejects a non-string optional field instead of coercing", () => {
      expect(() =>
        parseCetasEvent({
          type: "tool_args_delta",
          index: 0,
          delta: 42,
        }),
      ).toThrow("tool_args_delta.delta must be a string");
    });
  });

  test("returns null for an unknown versioned tag", () => {
    expect(parseCetasEvent({ type: "future_event" })).toBeNull();
  });

  describe("message delivery facts", () => {
    test("rejects an unknown delivery boundary instead of guessing", () => {
      expect(() =>
        parseCetasEvent({
          type: "message_applied",
          command_id: "follow_up_3",
          delivery: "model_step",
        }),
      ).toThrow("message_applied.delivery must be step or turn");
      expect(() =>
        parseCetasEvent({
          type: "message_undelivered",
          command_id: "follow_up_3",
          reason: "gone",
        }),
      ).toThrow("message_undelivered.delivery must be step or turn");
    });

    test("rejects the missing required fields", () => {
      expect(() =>
        parseCetasEvent({ type: "message_applied", delivery: "turn" }),
      ).toThrow("message_applied.command_id must be a string");
      expect(() =>
        parseCetasEvent({
          type: "message_undelivered",
          command_id: "follow_up_3",
          delivery: "turn",
        }),
      ).toThrow("message_undelivered.reason must be a string");
    });
  });

  test("subagent_event requires the tag fields", () => {
    expect(() =>
      parseCetasEvent({
        type: "subagent_event",
        child_session: "s",
        kind: "coder",
        ev: { type: "turn_started" },
      }),
    ).toThrow("subagent_event.parent_call must be a string");
  });

  test("subagent_event names an unknown inner type instead of hiding it", () => {
    // Version skew: the bridge wrapped a child tag the TS union does not
    // know yet. The envelope must degrade with the INNER tag named, not as
    // the misleading "unknown type subagent_event".
    expect(() =>
      parseCetasEvent({
        type: "subagent_event",
        child_session: "subagent-1",
        kind: "coder",
        parent_call: "call_9",
        ev: { type: "context_state" },
      }),
    ).toThrow("subagent_event.ev has unknown type context_state");
  });

  test("parses a question_event and normalizes every display field", () => {
    expect(
      parseCetasEvent({
        type: "question_event",
        label: "question_asked",
        data: {
          question_id: "question-3",
          short_id: "@q3",
          origin_call: "call-9",
          question: "Which env?",
          kind: "select",
          options: ["staging", "production", 7],
          asked_at: 100,
          deadline_at: 200,
        },
      }),
    ).toEqual({
      type: "question_event",
      label: "question_asked",
      data: {
        question_id: "question-3",
        short_id: "@q3",
        origin_call: "call-9",
        question: "Which env?",
        kind: "select",
        options: ["staging", "production"],
        asked_at: 100,
        deadline_at: 200,
      },
    });
  });

  test("a question_event without display fields degrades to defaults", () => {
    expect(
      parseCetasEvent({
        type: "question_event",
        label: "question_answered",
        data: { question_id: "question-1" },
      }),
    ).toEqual({
      type: "question_event",
      label: "question_answered",
      data: {
        question_id: "question-1",
        short_id: "",
        origin_call: "",
        question: "",
        kind: "input",
        options: [],
        asked_at: 0,
        deadline_at: 0,
      },
    });
  });

  test("a question_event without an id is malformed, not silently dropped", () => {
    expect(() =>
      parseCetasEvent({
        type: "question_event",
        label: "question_asked",
        data: { question: "no id" },
      }),
    ).toThrow("question_event.data.question_id");
  });
});
