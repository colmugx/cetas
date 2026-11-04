import { describe, expect, test } from "bun:test";
import { newSessionId } from "./session-id.ts";

describe("newSessionId", () => {
  test("matches UTC timestamp + 8-hex layout", () => {
    expect(newSessionId()).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_[0-9a-f]{8}$/,
    );
  });

  test("contains no ':' or path separators", () => {
    const id = newSessionId();
    expect(id.includes(":")).toBe(false);
    expect(id.includes("/")).toBe(false);
    expect(id.includes("\\")).toBe(false);
  });
});
