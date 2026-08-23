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
