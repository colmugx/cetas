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
});
