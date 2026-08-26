import { describe, expect, test } from "bun:test";
import {
  newSessionId,
  projectSessionsDir,
  sessionFilePath,
} from "./session-id.ts";

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

describe("projectSessionsDir", () => {
  test("encodes an absolute POSIX cwd (spaces kept)", () => {
    expect(projectSessionsDir("/home/u", "/Users/x/My Proj")).toBe(
      "/home/u/.cetas/sessions/--Users-x-My Proj--",
    );
  });

  test("encodes a Windows-style cwd including drive colon", () => {
    expect(projectSessionsDir("C:\\Users\\u", "C:\\Users\\x\\My Proj")).toBe(
      "C:\\Users\\u/.cetas/sessions/--C--Users-x-My Proj--",
    );
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
