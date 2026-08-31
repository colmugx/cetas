/**
 * terminal-shell.test.ts — exported pure helpers only. TerminalShell itself
 * needs a live pi-tui instance, so it is not constructed here.
 */

import { describe, expect, test } from "bun:test";
import { isAbortError, parsePositionalArgs } from "./terminal-shell.ts";

describe("parsePositionalArgs", () => {
  test("bare integer literals map to a list index", () => {
    expect(parsePositionalArgs("3")).toBe(JSON.stringify({ index: 3 }));
    expect(parsePositionalArgs("  12  ")).toBe(JSON.stringify({ index: 12 }));
    expect(parsePositionalArgs("-2")).toBe(JSON.stringify({ index: -2 }));
  });

  test("hex and exponent literals fall through to positional strings", () => {
    expect(parsePositionalArgs("0x10")).toBe(JSON.stringify({ _positional: "0x10" }));
    expect(parsePositionalArgs("1e3")).toBe(JSON.stringify({ _positional: "1e3" }));
  });

  test("non-numeric text falls through to positional strings", () => {
    expect(parsePositionalArgs("plan")).toBe(JSON.stringify({ _positional: "plan" }));
  });

  test("empty input produces an empty args object", () => {
    expect(parsePositionalArgs("")).toBe("{}");
    expect(parsePositionalArgs("   ")).toBe("{}");
  });
});

describe("isAbortError", () => {
  test("AbortError name marks an interrupt", () => {
    const error = new Error("signal is aborted without reason");
    error.name = "AbortError";
    expect(isAbortError(error)).toBe(true);
  });

  test("stringified MoonBit AgentError Cancelled shapes mark an interrupt", () => {
    expect(isAbortError("AgentError::Model(provider fetch failed: Cancelled)")).toBe(true);
    expect(isAbortError(new Error("AgentError::Interrupted(turn Cancelled by ESC)"))).toBe(
      true,
    );
  });

  test("a bare Cancelled message is a real failure, not an interrupt", () => {
    expect(isAbortError(new Error("task Cancelled by user"))).toBe(false);
    expect(isAbortError(new Error("Cancelled"))).toBe(false);
    expect(isAbortError("Cancelled")).toBe(false);
  });

  test("other error shapes are not interrupts", () => {
    expect(isAbortError(new Error("provider 500"))).toBe(false);
    expect(isAbortError(undefined)).toBe(false);
    expect(isAbortError(42)).toBe(false);
  });
});
