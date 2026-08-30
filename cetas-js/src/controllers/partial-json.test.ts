/**
 * partial-json.test.ts — truncation semantics of the streamed-args parser.
 *
 * The parser runs on the accumulated `arguments_delta` buffer at each flush;
 * these tests lock in exactly what survives a stream cut at every interesting
 * position (mid-key, mid-string, mid-escape, mid-number, mid-container).
 */

import { describe, expect, test } from "bun:test";
import { parsePartialJsonObject } from "./partial-json.ts";

describe("parsePartialJsonObject — complete pairs", () => {
  test("full valid object parses identically to JSON.parse", () => {
    const raw = '{"path":"src/a.md","count":3,"ok":true,"meta":null}';
    expect(parsePartialJsonObject(raw)).toEqual(JSON.parse(raw));
  });

  test("nested objects and arrays survive when complete", () => {
    const raw = '{"outer":{"inner":[1,"two",false]},"after":"yes"}';
    expect(parsePartialJsonObject(raw)).toEqual(JSON.parse(raw));
  });

  test("complete escapes decode: newline, tab, quote, backslash, unicode", () => {
    expect(parsePartialJsonObject('{"a":"l1\\nl2"}')).toEqual({ a: "l1\nl2" });
    expect(parsePartialJsonObject('{"a":"t\\tq\\"b\\\\c\\/d"}')).toEqual({
      a: 't\tq"b\\c/d',
    });
    expect(parsePartialJsonObject('{"a":"caf\\u00e9"}')).toEqual({ a: "café" });
    // Surrogate pair with two complete \uXXXX escapes.
    expect(parsePartialJsonObject('{"a":"\\ud83d\\ude00"}')).toEqual({
      a: "\u{1F600}",
    });
  });
});

describe("parsePartialJsonObject — cuts inside string values", () => {
  test("partial string contributes its partially-unescaped text", () => {
    expect(
      parsePartialJsonObject('{"path":"notes.md","content":"line1\\nline2\\nline'),
    ).toEqual({ path: "notes.md", content: "line1\nline2\nline" });
  });

  test("truncated \\u escape is dropped entirely (no partial hex leaks)", () => {
    expect(parsePartialJsonObject('{"a":"caf\\u0"')).toEqual({ a: "caf" });
    expect(parsePartialJsonObject('{"a":"x\\u12')).toEqual({ a: "x" });
  });

  test("trailing lone backslash is dropped, not emitted", () => {
    expect(parsePartialJsonObject('{"a":"ab\\')).toEqual({ a: "ab" });
  });

  test("empty opening key gets nothing; earlier pairs still survive", () => {
    expect(parsePartialJsonObject('{"keep":1,"op":')).toEqual({ keep: 1 });
    expect(parsePartialJsonObject('{"keep":1,"o')).toEqual({ keep: 1 });
  });

  test("cut before any value: colon-less keys contribute nothing", () => {
    expect(parsePartialJsonObject('{"pat')).toEqual({});
    expect(parsePartialJsonObject('{"path"')).toEqual({});
    expect(parsePartialJsonObject('{"path":')).toEqual({});
  });
});

describe("parsePartialJsonObject — non-string incomplete values", () => {
  test("truncated number never appears (could still grow)", () => {
    expect(parsePartialJsonObject('{"n":12')).toEqual({});
    expect(parsePartialJsonObject('{"n":-')).toEqual({});
    expect(parsePartialJsonObject('{"a":1,"n":4')).toEqual({ a: 1 });
  });

  test("numbers terminated by delimiter are complete", () => {
    expect(parsePartialJsonObject('{"n":42,"s":"tail')).toEqual({
      n: 42,
      s: "tail",
    });
    expect(parsePartialJsonObject('{"f":1.5e3,"g":true')).toEqual({
      f: 1500,
      g: true,
    });
  });

  test("partial true/false/null keyword contributes nothing but keeps siblings", () => {
    expect(parsePartialJsonObject('{"a":tru')).toEqual({});
    expect(parsePartialJsonObject('{"keep":false,"b":nul')).toEqual({
      keep: false,
    });
  });

  test("unfinished nested container drops only its own unfinished tail", () => {
    expect(
      parsePartialJsonObject('{"done":7,"nest":{"x":1,"y":"partial'),
    ).toEqual({ done: 7, nest: { x: 1, y: "partial" } });
    expect(parsePartialJsonObject('{"arr":[1,2,"thr')).toEqual({
      arr: [1, 2, "thr"],
    });
  });
});

describe("parsePartialJsonObject — hostile input never throws", () => {
  test("empty / whitespace / non-object input yields {}", () => {
    expect(parsePartialJsonObject("")).toEqual({});
    expect(parsePartialJsonObject("   ")).toEqual({});
    expect(parsePartialJsonObject("not json {{")).toEqual({});
    expect(parsePartialJsonObject("[1,2]")).toEqual({});
    expect(parsePartialJsonObject('"just a string"')).toEqual({});
  });

  test("garbage after the opening brace or between pairs stops gracefully", () => {
    expect(parsePartialJsonObject("{")).toEqual({});
    expect(parsePartialJsonObject("{garbage}")).toEqual({});
    expect(parsePartialJsonObject('{"a":1,??}')).toEqual({ a: 1 });
    expect(parsePartialJsonObject('{"a":12x}')).toEqual({});
    expect(parsePartialJsonObject("{\u0000\u0001}")).toEqual({});
  });

  test("result is always a plain object even when earlier scan succeeded", () => {
    const out = parsePartialJsonObject('{"only":"one"');
    expect(Object.keys(out)).toEqual(["only"]);
  });
});
