import { describe, expect, test } from "bun:test";
import { applyInsert, detectTrigger } from "./trigger";

describe("detectTrigger", () => {
  test("empty query at token start", () => {
    expect(detectTrigger("hello @", 7)).toEqual({
      kind: "file",
      query: "",
      start: 6,
      end: 7,
    });
  });

  test("file query up to whitespace", () => {
    expect(detectTrigger("look @src/ma", 12)).toEqual({
      kind: "file",
      query: "src/ma",
      start: 5,
      end: 12,
    });
  });

  test("skill mention", () => {
    expect(detectTrigger("use $refac", 10)).toEqual({
      kind: "skill",
      query: "refac",
      start: 4,
      end: 10,
    });
  });

  test("command spans spaces for arguments", () => {
    expect(detectTrigger("/model high", 11)).toEqual({
      kind: "command",
      query: "model high",
      start: 0,
      end: 11,
    });
  });

  test("command after whitespace mid-line", () => {
    const text = "try /comp";
    expect(detectTrigger(text, text.length)).toEqual({
      kind: "command",
      query: "comp",
      start: 4,
      end: 9,
    });
  });

  test("URL slash never triggers", () => {
    expect(detectTrigger("see https://example.com", 23)).toBeNull();
  });

  test("mid-word slash never triggers", () => {
    expect(detectTrigger("a/b", 3)).toBeNull();
  });

  test("newline ends command span", () => {
    expect(detectTrigger("/cmd\nnext", 9)).toBeNull();
  });

  test("plain text has no trigger", () => {
    expect(detectTrigger("just words", 10)).toBeNull();
  });
});

describe("applyInsert", () => {
  test("file insert replaces the span and parks the caret", () => {
    const trigger = { kind: "file" as const, query: "src/ma", start: 5, end: 12 };
    const result = applyInsert("look @src/ma rest", trigger, "@src/main.ts ");
    expect(result.text).toBe("look @src/main.ts  rest");
    expect(result.caret).toBe(18);
  });

  test("command insert keeps args editable", () => {
    const trigger = { kind: "command" as const, query: "mod", start: 0, end: 4 };
    const result = applyInsert("/mod", trigger, "/model ");
    expect(result.text).toBe("/model ");
    expect(result.caret).toBe(7);
  });
});
