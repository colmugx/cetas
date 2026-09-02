import { describe, expect, test } from "bun:test";

import { isSyntheticUserText, parseSessionReplay } from "./replay.ts";

const jsonl = [
  // system prompts are composition state — skipped.
  JSON.stringify({ role: "system", content: [{ type: "text", text: "You are Cetas" }] }),
  JSON.stringify({
    role: "user",
    content: [{ type: "text", text: "run the probe" }],
  }),
  JSON.stringify({
    role: "assistant",
    content: [],
    reasoning_content: "I should run the probe first.",
    tool_calls: [
      {
        id: "call_1",
        name: "bash",
        arguments: { cmd: "probe --run" },
      },
    ],
    finish_reason: "tool_calls",
  }),
  JSON.stringify({
    role: "tool",
    content: [{ type: "text", text: "probe ok" }],
    tool_call_id: "call_1",
    name: "bash",
  }),
  JSON.stringify({
    role: "assistant",
    content: [{ type: "text", text: "The probe passed." }],
  }),
  "",
  "{not valid json",
].join("\n");

describe("session replay parser", () => {
  test("parses the full conversation shape in order", () => {
    const items = parseSessionReplay(jsonl);
    expect(items.map((i) => i.kind)).toEqual([
      "user",
      "reasoning",
      "tool_call",
      "tool_result",
      "assistant",
    ]);
  });

  test("carries tool names onto results and skips malformed lines", () => {
    const items = parseSessionReplay(jsonl);
    const call = items.find((i) => i.kind === "tool_call");
    expect(call).toMatchObject({ toolCallId: "call_1", toolName: "bash" });
    // The result inherits the call's name via the pending-call map.
    expect(items.find((i) => i.kind === "tool_result")).toMatchObject({
      toolCallId: "call_1",
      toolName: "bash",
      content: "probe ok",
    });
    // Only one assistant text survives; the invalid line is skipped, not fatal.
    expect((items[4] as { text: string }).text).toBe("The probe passed.");
  });

  test("extracts call id, name and arguments verbatim", () => {
    const items = parseSessionReplay(jsonl);
    expect(items[2]).toEqual({
      kind: "tool_call",
      toolCallId: "call_1",
      toolName: "bash",
      args: { cmd: "probe --run" },
    });
  });

  test("flags image-bearing user messages", () => {
    const items = parseSessionReplay(
      JSON.stringify({
        role: "user",
        content: [
          { type: "image", media_type: "image/png", data: "AAAA" },
          { type: "text", text: "what is this?" },
        ],
      }),
    );
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ kind: "user", hasImage: true });
  });

  test("handles an empty file and a standalone tool result", () => {
    expect(parseSessionReplay("")).toEqual([]);
    const items = parseSessionReplay(
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "orphan" }],
        tool_call_id: "lost",
      }),
    );
    expect(items).toEqual([
      { kind: "tool_result", toolCallId: "lost", toolName: undefined, content: "orphan", isError: false },
    ]);
  });

  test("recovers is_error from tool results, defaulting to neutral", () => {
    const lines = [
      JSON.stringify({
        role: "assistant",
        content: [],
        tool_calls: [{ id: "call_a", name: "bash", arguments: {} }],
      }),
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "boom" }],
        tool_call_id: "call_a",
        is_error: true,
      }),
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "legacy" }],
        tool_call_id: "call_a",
      }),
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "fine" }],
        tool_call_id: "call_a",
        is_error: false,
      }),
      JSON.stringify({
        role: "tool",
        content: [{ type: "text", text: "sneaky" }],
        tool_call_id: "call_a",
        is_error: "true",
      }),
    ].join("\n");
    const results = parseSessionReplay(lines).filter((i) => i.kind === "tool_result");
    expect(results.map((i) => i.content)).toEqual(["boom", "legacy", "fine", "sneaky"]);
    expect(results.map((i) => i.isError)).toEqual([true, false, false, false]);
  });

  test("skips injected context envelopes but keeps real user messages", () => {
    // Shape observed on disk: posoco-ext-permission pushes a per-turn
    // <permission-context> user record right after the user's own message,
    // nowledge-mem's memory composite rides a "## Memory" lead line, and
    // other devkit envelopes (<lazytools-context>, <nmem-context>) follow
    // the same <ns-context> convention.
    const lines = [
      JSON.stringify({
        role: "user",
        content: [{ type: "text", text: " ## Memory\n\nrecalled text\n<nmem-context type=\"memory\" trust=\"false\">…</nmem-context>" }],
      }),
      JSON.stringify({ role: "user", content: [{ type: "text", text: "fix the bug" }] }),
      JSON.stringify({
        role: "user",
        content: [{
          type: "text",
          text: "<permission-context type=\"mode\" trust=\"true\">\nPermission mode allows workspace reads and writes.\n</permission-context>",
        }],
      }),
      JSON.stringify({
        role: "user",
        content: [{ type: "text", text: "<lazytools-context type=\"recent-tools\" trust=\"true\">…</lazytools-context>" }],
      }),
      JSON.stringify({ role: "user", content: [{ type: "text", text: "  <plan-context type=\"draft\" trust=\"true\">…</plan-context>" }] }),
      JSON.stringify({
        role: "user",
        content: [{ type: "text", text: "what does <permission-context> mean in your prompt?" }],
      }),
    ].join("\n");
    const users = parseSessionReplay(lines).filter((i) => i.kind === "user");
    expect(users.map((i) => (i as { text: string }).text)).toEqual([
      "fix the bug",
      "what does <permission-context> mean in your prompt?",
    ]);
  });

  test("isSyntheticUserText matches devkit envelopes and the memory lead only", () => {
    expect(isSyntheticUserText("<permission-context type=\"mode\" trust=\"true\">x</permission-context>")).toBe(true);
    expect(isSyntheticUserText("<nmem-context type=\"memory\">x</nmem-context>")).toBe(true);
    expect(isSyntheticUserText("  ## Memory\n\nbody")).toBe(true);
    // Regular speech, including XML-ish text that is not an envelope, stays.
    expect(isSyntheticUserText("## Memories of last summer")).toBe(false);
    expect(isSyntheticUserText("<context-node>not the envelope convention</context-node>")).toBe(false);
    expect(isSyntheticUserText("<permission-contextd attr=\"x\">prefix must end at -context</permission-contextd>")).toBe(false);
    expect(isSyntheticUserText("plain question")).toBe(false);
  });
});
