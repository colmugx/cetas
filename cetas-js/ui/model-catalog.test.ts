import { describe, expect, test } from "bun:test";
import { parseModelPickerOutcome } from "./model-catalog.ts";

describe("model catalog wire boundary", () => {
  test("malformed success payload is rejected with path context", () => {
    expect(() => parseModelPickerOutcome(JSON.stringify({type:"success",structured:[{id:"demo"}]})))
      .toThrow("model outcome.structured[0].thinking_efforts");
  });
  test("unknown variants never silently coerce to success", () => {
    expect(() => parseModelPickerOutcome('{"type":"something_new"}')).toThrow("unsupported");
  });
});
