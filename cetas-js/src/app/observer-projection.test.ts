import { describe, expect, test } from "bun:test";
import { projectObserverEvent } from "./observer-projection.ts";

describe("projectObserverEvent", () => {
  test("unknown or broken payloads never throw or fabricate an operation", () => {
    for (const raw of ["not-json", "null", "[]", "{}", '{"type":"custom","source":1}']) {
      expect(projectObserverEvent(raw).operation).toBeUndefined();
    }
  });

  test("passes through lifecycle tags without treating foreign customs as operations", () => {
    expect(projectObserverEvent('{"type":"turn_started"}')).toEqual({ type: "turn_started" });
    expect(projectObserverEvent('{"type":"custom","source":"other","label":"hi","data":{}}'))
      .toEqual({ type: "custom" });
  });
});
