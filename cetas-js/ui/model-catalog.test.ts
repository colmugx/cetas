import { describe, expect, test } from "bun:test";
import { parseModelPickerOutcome, formatPickCandidateNotices } from "./model-catalog.ts";

describe("model catalog wire boundary", () => {
  test("malformed success payload is rejected with path context", () => {
    expect(() => parseModelPickerOutcome(JSON.stringify({type:"success",structured:[{id:"demo"}]})))
      .toThrow("model outcome.structured[0].thinking_efforts");
  });
  test("unknown variants never silently coerce to success", () => {
    expect(() => parseModelPickerOutcome('{"type":"something_new"}')).toThrow("unsupported");
  });
  test("candidate rank and numeric fields are validated", () => {
    const result = {candidates:[{slot_id:"s",model:"m",effort:"high",iq:24,cost_usd:1.5}]};
    expect(formatPickCandidateNotices(result)).toEqual(["candidate 2 — m:high · IQ 24.0 · $1.50"]);
    expect(() => formatPickCandidateNotices({candidates:[{...result.candidates[0],iq:"24"}]}))
      .toThrow("pick outcome.candidates[0].iq");
  });
});
