import { describe, expect, test } from "bun:test";

import { parseCetasEvent } from "./events.ts";

describe("parseCetasEvent", () => {
  test("parses the exact turn-start wire shape", () => {
    expect(parseCetasEvent({ type: "turn_started" })).toEqual({
      type: "turn_started",
    });
  });

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

  test("parses tool_call_completed with a structured payload", () => {
    expect(
      parseCetasEvent({
        type: "tool_call_completed",
        tool_call_id: "tc1",
        result: "Found 2 matches:\n",
        is_error: false,
        structured: { summary: "2 matches", count: 2 },
      }),
    ).toEqual({
      type: "tool_call_completed",
      tool_call_id: "tc1",
      result: "Found 2 matches:\n",
      is_error: false,
      structured: { summary: "2 matches", count: 2 },
    });
  });

  test("structured stays absent when the bridge omits it", () => {
    expect(
      parseCetasEvent({
        type: "tool_call_completed",
        tool_call_id: "tc1",
        result: "ok",
        is_error: false,
      }),
    ).toEqual({
      type: "tool_call_completed",
      tool_call_id: "tc1",
      result: "ok",
      is_error: false,
    });
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
    test("parses the full first-fragment shape", () => {
      expect(
        parseCetasEvent({
          type: "tool_args_delta",
          index: 0,
          id: "call_1",
          name: "write",
          delta: '{"path":"a',
        }),
      ).toEqual({
        type: "tool_args_delta",
        index: 0,
        id: "call_1",
        name: "write",
        delta: '{"path":"a',
      });
    });

    test("parses a minimal later fragment (index + delta only)", () => {
      expect(
        parseCetasEvent({ type: "tool_args_delta", index: 2, delta: "abc" }),
      ).toEqual({ type: "tool_args_delta", index: 2, delta: "abc" });
    });

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

  test("parses config_changed emitted by Agent::update_model", () => {
    expect(
      parseCetasEvent({
        type: "config_changed",
        field: "model",
        old: "deepseek-chat",
        new: "deepseek-reasoner",
      }),
    ).toEqual({
      type: "config_changed",
      field: "model",
      old: "deepseek-chat",
      new: "deepseek-reasoner",
    });
  });

  test("parses config_warning emitted on invalid reasoning_effort", () => {
    expect(
      parseCetasEvent({
        type: "config_warning",
        field: "reasoning_effort",
        value: "absurd",
        reason: "active modelport does not accept this value",
      }),
    ).toEqual({
      type: "config_warning",
      field: "reasoning_effort",
      value: "absurd",
      reason: "active modelport does not accept this value",
    });
  });
});
