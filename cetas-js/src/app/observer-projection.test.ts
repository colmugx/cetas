import { describe, expect, test } from "bun:test";
import { projectObserverEvent } from "./observer-projection.ts";

describe("projectObserverEvent", () => {
  test("unknown or broken payloads never throw or fabricate an operation", () => {
    for (const raw of ["not-json", "null", "[]", "{}", '{"type":"custom","source":1}']) {
      expect(projectObserverEvent(raw).operation).toBeUndefined();
    }
  });

  test("queued-message delivery facts carry the command id and boundary", () => {
    expect(
      projectObserverEvent(
        '{"type":"message_applied","command_id":"follow_up_1","delivery":"turn"}',
      ).delivery,
    ).toEqual({ kind: "applied", commandId: "follow_up_1", delivery: "turn" });
    expect(
      projectObserverEvent(
        '{"type":"message_undelivered","command_id":"follow_up_2","delivery":"turn","reason":"operation ended before delivery"}',
      ).delivery,
    ).toEqual({
      kind: "undelivered",
      commandId: "follow_up_2",
      delivery: "turn",
      reason: "operation ended before delivery",
    });
  });

  test("a malformed delivery fact degrades to the bare type", () => {
    for (const raw of [
      '{"type":"message_applied","delivery":"turn"}',
      '{"type":"message_applied","command_id":"","delivery":"turn"}',
      '{"type":"message_applied","command_id":"c1","delivery":"wave"}',
    ]) {
      const projection = projectObserverEvent(raw);
      expect(projection.type).toBe("message_applied");
      expect(projection.delivery).toBeUndefined();
    }
  });
});
