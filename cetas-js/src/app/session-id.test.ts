import { describe, expect, test } from "bun:test";
import { newSessionId, sessionFilePath } from "./session-id.ts";

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

  test("two calls differ", () => {
    expect(newSessionId()).not.toBe(newSessionId());
  });
});

describe("sessionFilePath", () => {
  test("appends the .jsonl transcript name to the sessions dir", () => {
    expect(
      sessionFilePath(
        "/h/.cetas/sessions/--Users-x-proj--",
        "2026-08-26T07-21-33-012Z_a1b2c3d4",
      ),
    ).toBe("/h/.cetas/sessions/--Users-x-proj--/2026-08-26T07-21-33-012Z_a1b2c3d4.jsonl");
  });
});
