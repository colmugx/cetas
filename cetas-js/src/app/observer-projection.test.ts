import { describe, expect, test } from "bun:test";
import { projectObserverEvent } from "./observer-projection.ts";

describe("projectObserverEvent", () => {
  test("unknown or broken payloads never throw or fabricate an operation", () => {
    for (const raw of ["not-json", "null", "[]", "{}", '{"type":"custom","source":1}']) {
      expect(projectObserverEvent(raw).operation).toBeUndefined();
    }
  });
});
