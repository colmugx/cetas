import { describe, expect, test } from "bun:test";
import { copyTextToClipboard } from "./clipboard.ts";

describe("terminal clipboard", () => {
  test("uses native clipboard when available outside multiplexers", async () => {
    const copied: string[] = [];
    const sequences: string[] = [];
    const result = await copyTextToClipboard("hello", {
      native: { setText(text) { copied.push(text); } },
      terminal: { isTTY: true, write(text) { sequences.push(text); } },
      preferTerminal: false,
    });
    expect(result).toBe("native");
    expect(copied).toEqual(["hello"]);
    expect(sequences).toEqual([]);
  });

  test("uses OSC 52 when native clipboard cannot write", async () => {
    const sequences: string[] = [];
    const result = await copyTextToClipboard("selection", {
      native: {},
      terminal: { isTTY: true, write(text) { sequences.push(text); } },
      preferTerminal: false,
    });
    expect(result).toBe("terminal");
    expect(sequences).toHaveLength(1);
  });

  test("falls back to OSC 52 when the native clipboard is absent", async () => {
    const sequences: string[] = [];
    const result = await copyTextToClipboard("你好\nhello", {
      native: null,
      terminal: { isTTY: true, write(text) { sequences.push(text); } },
      preferTerminal: false,
    });
    expect(result).toBe("terminal");
    expect(sequences).toEqual([
      `\x1b]52;c;${Buffer.from("你好\nhello", "utf8").toString("base64")}\x07`,
    ]);
  });

  test("prefers the terminal clipboard inside a multiplexer", async () => {
    const copied: string[] = [];
    const sequences: string[] = [];
    const result = await copyTextToClipboard("selection", {
      native: { setText(text) { copied.push(text); } },
      terminal: { isTTY: true, write(text) { sequences.push(text); } },
      preferTerminal: true,
    });
    expect(result).toBe("terminal");
    expect(sequences).toHaveLength(1);
    expect(copied).toEqual([]);
  });

  test("falls back to native when terminal transport cannot write", async () => {
    const copied: string[] = [];
    const result = await copyTextToClipboard("selection", {
      native: { setText(text) { copied.push(text); } },
      terminal: { isTTY: false, write() { throw new Error("unexpected write"); } },
      preferTerminal: true,
    });
    expect(result).toBe("native");
    expect(copied).toEqual(["selection"]);
  });

  test("handles native errors and safely reports unsupported transports", async () => {
    const sent: string[] = [];
    const fallback = await copyTextToClipboard("selection", {
      native: { setText() { throw new Error("unavailable"); } },
      terminal: { isTTY: true, write(text) { sent.push(text); } },
      preferTerminal: false,
    });
    expect(fallback).toBe("terminal");
    expect(sent).toHaveLength(1);

    const unsupported = await copyTextToClipboard("selection", {
      native: null,
      terminal: { isTTY: false, write() { throw new Error("no TTY"); } },
    });
    expect(unsupported).toBe("unavailable");
  });

  test("does not report OSC 52 support after a write failure", async () => {
    const result = await copyTextToClipboard("selection", {
      native: null,
      terminal: { isTTY: true, write() { throw new Error("closed stream"); } },
    });
    expect(result).toBe("unavailable");
  });
});
