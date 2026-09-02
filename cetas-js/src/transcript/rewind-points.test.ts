import { describe, expect, test } from "bun:test";

import { listRewindPoints, readUserMessage } from "./rewind-points.ts";

const META = JSON.stringify({ format: "cetas-session", version: 1 });

function userMsg(text: string): string {
  return JSON.stringify({ role: "user", content: [{ type: "text", text }] });
}

function assistantMsg(text: string): string {
  return JSON.stringify({ role: "assistant", content: [{ type: "text", text }] });
}

describe("rewind point enumeration", () => {
  test("collects user messages in order across mixed roles", () => {
    const jsonl = [
      META,
      userMsg("first prompt"),
      assistantMsg("working on it"),
      userMsg("second prompt"),
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "ok" }],
        tool_call_id: "call_1",
      }),
      assistantMsg("done"),
      userMsg("third prompt"),
    ].join("\n");
    expect(listRewindPoints(jsonl)).toEqual([
      { messageIndex: 0, preview: "first prompt" },
      { messageIndex: 2, preview: "second prompt" },
      { messageIndex: 5, preview: "third prompt" },
    ]);
  });

  test("keeps message indices aligned after malformed and blank lines", () => {
    const jsonl = [
      META,
      userMsg("before the gap"),
      "{not valid json",
      "",
      assistantMsg("survivor"),
      userMsg("after the gap"),
    ].join("\n");
    expect(listRewindPoints(jsonl)).toEqual([
      { messageIndex: 0, preview: "before the gap" },
      // Physical line 5 → message index 4, despite the two skipped lines above.
      { messageIndex: 4, preview: "after the gap" },
    ]);
  });

  test("returns empty for metadata-only, blank, and empty transcripts", () => {
    expect(listRewindPoints(META)).toEqual([]);
    expect(listRewindPoints(`${META}\n`)).toEqual([]);
    expect(listRewindPoints("")).toEqual([]);
  });

  test("flattens multi-line text and marks image-bearing messages", () => {
    const jsonl = [
      META,
      userMsg("line one\nline two\n\nline three"),
      JSON.stringify({
        role: "user",
        content: [{ type: "image", media_type: "image/png", data: "AAAA" }],
      }),
      JSON.stringify({
        role: "user",
        content: [
          { type: "text", text: "what is in this" },
          { type: "image", media_type: "image/png", data: "AAAA" },
        ],
      }),
    ].join("\n");
    const points = listRewindPoints(jsonl);
    expect(points[0]?.preview).toBe("line one line two line three");
    expect(points[1]?.preview).toBe("(image)");
    expect(points[2]?.preview).toBe("what is in this (image)");
  });

  test("truncates long previews to ~60 chars with an ellipsis", () => {
    const points = listRewindPoints([META, userMsg("x".repeat(120))].join("\n"));
    expect(points[0]?.preview.length).toBe(60);
    expect(points[0]?.preview.endsWith("…")).toBe(true);
  });

  test("skips whitespace-only user messages without breaking indices", () => {
    const jsonl = [
      META,
      JSON.stringify({ role: "user", content: [{ type: "text", text: "   " }] }),
      userMsg("real prompt"),
    ].join("\n");
    expect(listRewindPoints(jsonl)).toEqual([{ messageIndex: 1, preview: "real prompt" }]);
  });

  test("synthetic context envelopes occupy a slot but are never rewind targets", () => {
    const jsonl = [
      META,
      userMsg(" ## Memory\n\n<nmem-context type=\"memory\" trust=\"false\">…</nmem-context>"),
      userMsg("real prompt"),
      userMsg("<permission-context type=\"mode\" trust=\"true\">…</permission-context>"),
      userMsg("follow-up"),
    ].join("\n");
    expect(listRewindPoints(jsonl)).toEqual([
      { messageIndex: 1, preview: "real prompt" },
      { messageIndex: 3, preview: "follow-up" },
    ]);
    // The editor refill refuses synthetic rows at the same addresses.
    expect(readUserMessage(jsonl, 0)).toBeNull();
    expect(readUserMessage(jsonl, 2)).toBeNull();
    expect(readUserMessage(jsonl, 1)).toBe("real prompt");
  });
});

describe("readUserMessage", () => {
  test("returns the full multi-line text at listRewindPoints addressing", () => {
    const jsonl = [
      META,
      userMsg("line one\nline two"),
      assistantMsg("ok"),
      userMsg("second prompt"),
    ].join("\n");
    expect(readUserMessage(jsonl, 0)).toBe("line one\nline two");
    expect(readUserMessage(jsonl, 2)).toBe("second prompt");
  });

  test("out-of-range and negative indices return null", () => {
    const jsonl = [META, userMsg("only")].join("\n");
    expect(readUserMessage(jsonl, 1)).toBeNull();
    expect(readUserMessage(jsonl, -2)).toBeNull();
  });

  test("non-user rows — including the metadata header — return null", () => {
    const jsonl = [META, assistantMsg("hi")].join("\n");
    expect(readUserMessage(jsonl, -1)).toBeNull();
    expect(readUserMessage(jsonl, 0)).toBeNull();
  });

  test("blank and malformed physical lines keep the addressing aligned", () => {
    const jsonl = [
      META,
      userMsg("before"),
      "{not valid json",
      "",
      userMsg("after"),
    ].join("\n");
    expect(readUserMessage(jsonl, 1)).toBeNull();
    expect(readUserMessage(jsonl, 2)).toBeNull();
    expect(readUserMessage(jsonl, 3)).toBe("after");
  });

  test("an image-only user message yields empty text, not null", () => {
    const jsonl = [
      META,
      JSON.stringify({
        role: "user",
        content: [{ type: "image", media_type: "image/png", data: "AAAA" }],
      }),
    ].join("\n");
    expect(readUserMessage(jsonl, 0)).toBe("");
  });
});
