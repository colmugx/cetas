/**
 * terminal-shell.test.ts — exported pure helpers, plus the global key dispatch
 * (handleInput) exercised headlessly: a real TUI over a stub terminal object
 * never touches stdin/stdout, so the shell can be constructed and driven with
 * raw key sequences.
 */

import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TUI, TuiMainScreen } from "@earendil-works/pi-tui";
import {
  isAbortError,
  matchLocalSlash,
  parseCetasEventLenient,
  parsePositionalArgs,
  positionalArgsFor,
  shouldOpenRewindOnEscape,
  TerminalShell,
} from "./terminal-shell.ts";
import type { CommandDescriptor } from "../src/app/index.ts";

/** Swap console.warn for a recorder; call restore() when done. */
function captureWarn(): { warns: string[]; restore(): void } {
  const warns: string[] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    warns.push(args.map((item) => String(item)).join(" "));
  };
  return {
    warns,
    restore: () => {
      console.warn = original;
    },
  };
}

/** Shell + headless TUI pair; the session transcript has one rewind point. */
function makeShell(): { shell: TerminalShell; tui: TUI } {
  const terminal = {
    write: () => {},
    hideCursor: () => {},
    showCursor: () => {},
    clearScreen: () => {},
    cursorTo: () => {},
    getRows: () => 40,
    getColumns: () => 120,
  };
  const tui = new TuiMainScreen(terminal as never);
  const sessionsDir = mkdtempSync(join(tmpdir(), "cetas-shell-test-"));
  const sessionId = "2026-09-01T00-00-00-000Z_deadbeef";
  writeFileSync(
    join(sessionsDir, `${sessionId}.jsonl`),
    [
      JSON.stringify({ version: 1 }),
      JSON.stringify({
        role: "user",
        content: [{ type: "text", text: "hello" }],
      }),
    ].join("\n") + "\n",
  );
  const shell = new TerminalShell({
    tui,
    cwd: "/tmp",
    sessionsDir,
    maxToolRounds: 8,
    initialSessionId: sessionId,
  });
  return { shell, tui };
}

describe("parsePositionalArgs", () => {
  test("bare integer literals map to a list index", () => {
    expect(parsePositionalArgs("3")).toBe(JSON.stringify({ index: 3 }));
    expect(parsePositionalArgs("  12  ")).toBe(JSON.stringify({ index: 12 }));
    expect(parsePositionalArgs("-2")).toBe(JSON.stringify({ index: -2 }));
  });

  test("hex and exponent literals fall through to positional strings", () => {
    expect(parsePositionalArgs("0x10")).toBe(
      JSON.stringify({ _positional: "0x10" }),
    );
    expect(parsePositionalArgs("1e3")).toBe(
      JSON.stringify({ _positional: "1e3" }),
    );
  });

  test("non-numeric text falls through to positional strings", () => {
    expect(parsePositionalArgs("plan")).toBe(
      JSON.stringify({ _positional: "plan" }),
    );
  });

  test("empty input produces an empty args object", () => {
    expect(parsePositionalArgs("")).toBe("{}");
    expect(parsePositionalArgs("   ")).toBe("{}");
  });
});

describe("matchLocalSlash", () => {
  test("/quit routes to the exit route via alias", () => {
    expect(matchLocalSlash("/quit")?.id).toBe("exit");
    expect(matchLocalSlash("/exit")?.id).toBe("exit");
  });

  test("/model is a local route; arg logic stays in the handler", () => {
    expect(matchLocalSlash("/model")?.id).toBe("model");
    expect(matchLocalSlash("/skills")?.id).toBe("skills");
  });

  test("/name is unknown locally and falls through to the extension fallback", () => {
    expect(matchLocalSlash("/name")).toBeUndefined();
  });

  test("/handoff is unknown and falls through to the extension fallback", () => {
    expect(matchLocalSlash("/handoff")).toBeUndefined();
  });

  test("matching is case-sensitive", () => {
    expect(matchLocalSlash("/QUIT")).toBeUndefined();
    expect(matchLocalSlash("/Model")).toBeUndefined();
  });
});

describe("positionalArgsFor", () => {
  function descriptor(partial: {
    id: string;
    params?: CommandDescriptor["params"];
    aliases?: readonly string[];
  }): CommandDescriptor {
    return {
      id: partial.id,
      label: partial.id,
      description: "",
      category: "session",
      ctype: "input",
      params: partial.params ?? [],
      aliases: partial.aliases ?? [],
      visible: true,
    };
  }

  const catalog = [
    descriptor({
      id: "name",
      params: [
        {
          name: "value",
          label: "Title",
          description: "",
          ptype: "str",
          required: true,
          positional: true,
        },
      ],
    }),
    descriptor({
      id: "wrap",
      params: [
        {
          name: "action",
          label: "Action",
          description: "",
          ptype: "str",
          required: true,
          positional: true,
        },
        {
          name: "name",
          label: "Name",
          description: "",
          ptype: "str",
          required: false,
          positional: true,
        },
      ],
    }),
  ];

  test("a single declared positional param receives the raw remainder", () => {
    expect(positionalArgsFor("/name", "my title", catalog)).toBe(
      JSON.stringify({ value: "my title" }),
    );
    expect(positionalArgsFor("/name", "  spaced  ", catalog)).toBe(
      JSON.stringify({ value: "spaced" }),
    );
  });

  test("several declared positional params keep the generic _positional", () => {
    expect(positionalArgsFor("/wrap", "load coding-fast", catalog)).toBe(
      JSON.stringify({ _positional: "load coding-fast" }),
    );
  });

  test("commands without a declared positional keep the generic _positional", () => {
    expect(positionalArgsFor("/statusbar", "extra", catalog)).toBe(
      JSON.stringify({ _positional: "extra" }),
    );
    expect(positionalArgsFor("/unknown", "extra", catalog)).toBe(
      JSON.stringify({ _positional: "extra" }),
    );
  });

  test("empty args and dedicated shapers pass through untouched", () => {
    expect(positionalArgsFor("/name", "", catalog)).toBe("{}");
    expect(positionalArgsFor("/model", "kimi high", catalog)).toBe(
      JSON.stringify({ slot: "kimi", effort: "high" }),
    );
    expect(positionalArgsFor("/login", "prov oauth", catalog)).toBe(
      JSON.stringify({ provider: "prov", method: "oauth" }),
    );
  });
});

describe("shouldOpenRewindOnEscape", () => {
  test("a second press inside the 500ms window opens rewind", () => {
    expect(shouldOpenRewindOnEscape(1000, 1000)).toBe(true);
    expect(shouldOpenRewindOnEscape(1000, 1499)).toBe(true);
  });

  test("outside the window it stays a single escape", () => {
    expect(shouldOpenRewindOnEscape(1000, 1500)).toBe(false);
    expect(shouldOpenRewindOnEscape(1000, 9999)).toBe(false);
  });

  test("no previously recorded escape never opens", () => {
    expect(shouldOpenRewindOnEscape(undefined, 1000)).toBe(false);
  });

  test("a backwards gap (clock skew) does not count as a double press", () => {
    expect(shouldOpenRewindOnEscape(2000, 1500)).toBe(false);
  });

  test("the window width is injectable", () => {
    expect(shouldOpenRewindOnEscape(1000, 1500, 501)).toBe(true);
    expect(shouldOpenRewindOnEscape(1000, 1500, 500)).toBe(false);
  });
});

describe("parseCetasEventLenient", () => {
  test("parses a valid event", () => {
    expect(parseCetasEventLenient('{"type":"turn_started"}')).toEqual({
      event: { type: "turn_started" },
    });
    expect(
      parseCetasEventLenient(
        '{"type":"turn_failed","error_message":"x","error_kind":"Model"}',
      ),
    ).toEqual({
      event: { type: "turn_failed", error_message: "x", error_kind: "Model" },
    });
  });

  test("garbage json is skipped, never throws", () => {
    const outcome = parseCetasEventLenient("{not json at all");
    expect(outcome).toEqual({ skipped: "unparseable json" });
    expect(() => parseCetasEventLenient("{not json at all")).not.toThrow();
  });

  test("an unknown type from a newer MoonBit bundle is skipped", () => {
    expect(parseCetasEventLenient('{"type":"definitely_new_thing"}')).toEqual({
      skipped: "unknown type definitely_new_thing",
    });
    expect(() =>
      parseCetasEventLenient('{"type":"definitely_new_thing"}'),
    ).not.toThrow();
  });

  test("a malformed known type is skipped, never throws", () => {
    // turn_failed without its required fields.
    const outcome = parseCetasEventLenient('{"type":"turn_failed"}');
    expect(outcome).toEqual({ skipped: "malformed turn_failed" });
    expect(() =>
      parseCetasEventLenient('{"type":"turn_failed"}'),
    ).not.toThrow();
    expect(parseCetasEventLenient('"just a string"')).toEqual({
      skipped: "malformed (no type)",
    });
  });
});

/** Drive one raw sequence through the real TUI → shell dispatch path. */
function sendKey(tui: TUI, data: string): void {
  // pi-tui's terminal-data entry is handleTerminalInput; it runs the full
  // listener → overlay → focused-component dispatch.
  (tui as any).handleTerminalInput(data);
}

describe("handleInput key-release filtering", () => {
  // Kitty-protocol terminals report event types, so one physical keypress
  // arrives as a press sequence plus a release sequence (~0ms apart). The
  // TUI filters releases only for the focused component — input listeners
  // get both, so handleInput itself must treat a release as "not a press".

  test("one physical ESC press does not open the rewind picker", () => {
    const { shell, tui } = makeShell();
    sendKey(tui, "\x1b[27;1u"); // press
    sendKey(tui, "\x1b[27;1:3u"); // release
    expect((shell as any).rewindOverlay.isActive).toBe(false);
  });

  test("two independent ESC presses open the rewind picker", () => {
    const { shell, tui } = makeShell();
    sendKey(tui, "\x1b[27;1u");
    sendKey(tui, "\x1b[27;1:3u");
    sendKey(tui, "\x1b[27;1u");
    sendKey(tui, "\x1b[27;1:3u");
    expect((shell as any).rewindOverlay.isActive).toBe(true);
  });

  test("one physical ctrl+o press toggles tool output exactly once", () => {
    const { shell, tui } = makeShell();
    sendKey(tui, "\x1b[116;5u"); // ctrl+t press — must not touch tool state
    sendKey(tui, "\x1b[116;5:3u"); // ctrl+t release
    expect((shell as any).toolOutputExpanded).toBe(false);
    sendKey(tui, "\x1b[111;5u"); // ctrl+o press
    sendKey(tui, "\x1b[111;5:3u"); // ctrl+o release
    expect((shell as any).toolOutputExpanded).toBe(true);
  });

  test("legacy terminals without event types still toggle once per byte", () => {
    const { shell, tui } = makeShell();
    sendKey(tui, "\x14"); // raw ctrl+t
    sendKey(tui, "\x0f"); // raw ctrl+o
    expect((shell as any).toolOutputExpanded).toBe(true);
  });
});

describe("handleObserverEvent FFI degrade path", () => {
  test("skipped events warn and render at most one notice per turn window", () => {
    const { shell } = makeShell();
    const { warns, restore } = captureWarn();
    try {
      (shell as any).handleObserverEvent("{broken");
      (shell as any).handleObserverEvent('{"type":"definitely_new_thing"}');
      expect(warns).toHaveLength(2);
      const transcript = () => (shell as any).transcript.render(200).join("\n");
      const notices = () =>
        transcript().match(/unrecognized bridge event/g) ?? [];
      expect(notices()).toHaveLength(1);
      expect(transcript()).toContain("(last: unparseable json)");

      // turn_started resets the window: the next skip may notice again.
      (shell as any).handleObserverEvent('{"type":"turn_started"}');
      (shell as any).handleObserverEvent('{"type":"also_unknown"}');
      expect(notices()).toHaveLength(2);
    } finally {
      restore();
    }
  });

  test("never throws, even on garbage bytes", () => {
    const { shell } = makeShell();
    const { restore } = captureWarn();
    try {
      expect(() =>
        (shell as any).handleObserverEvent("not json"),
      ).not.toThrow();
      expect(() => (shell as any).handleObserverEvent("[]")).not.toThrow();
    } finally {
      restore();
    }
  });
});

describe("handleCatalogRefresh transcript policy", () => {
  test("refreshed entries are silent; failures keep one warning line", () => {
    const { shell } = makeShell();
    (shell as any).handleCatalogRefresh({
      results: [
        { provider: "deepseek", status: "refreshed", slots: 42 },
        {
          provider: "openai",
          status: "failed",
          reason: "catalog endpoint unavailable",
        },
      ],
    });
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).not.toContain("model catalog refreshed");
    expect(transcript).toContain(
      "⚠ openai catalog refresh failed: catalog endpoint unavailable — keeping current slots",
    );
  });
});

describe("handleUiRequest FFI degrade path", () => {
  test("answers unparseable bytes with a malformed_request ui_response", async () => {
    const { shell } = makeShell();
    const { restore } = captureWarn();
    try {
      await expect((shell as any).handleUiRequest("{broken")).resolves.toBe(
        JSON.stringify({
          type: "ui_response",
          request_id: "unknown",
          error: { code: "malformed_request" },
        }),
      );
    } finally {
      restore();
    }
  });

  test("a malformed auth_prompt falls through to the guarded generic path", async () => {
    const { shell } = makeShell();
    const { restore } = captureWarn();
    try {
      await expect(
        (shell as any).handleUiRequest(
          JSON.stringify({ type: "auth_prompt", request: { type: "secret" } }),
        ),
      ).resolves.toBe(
        JSON.stringify({
          type: "ui_response",
          request_id: "unknown",
          error: { code: "malformed_request" },
        }),
      );
    } finally {
      restore();
    }
  });
});

describe("isAbortError", () => {
  test("AbortError name marks an interrupt", () => {
    const error = new Error("signal is aborted without reason");
    error.name = "AbortError";
    expect(isAbortError(error)).toBe(true);
  });

  test("the provider's stable category=cancelled marker marks an interrupt", () => {
    expect(
      isAbortError(
        new Error(
          "AgentError::Model(model transport: OpenAI transport failure (stage=read_stream, category=cancelled))",
        ),
      ),
    ).toBe(true);
    expect(
      isAbortError(
        "AgentError::Model(model transport: OpenAI transport failure (stage=wait_headers, category=cancelled))",
      ),
    ).toBe(true);
  });

  test("a bare Cancelled message is a real failure, not an interrupt", () => {
    expect(
      isAbortError(new Error("AgentError::Model(provider fetch failed: Cancelled)")),
    ).toBe(false);
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

describe("operation lifecycle wire events", () => {
  function transcriptOf(shell: TerminalShell): string {
    return (shell as any).transcript.render(200).join("\n");
  }

  test("compact started/finished and completed finalize render without skip notices", () => {
    const { shell } = makeShell();
    const { warns, restore } = captureWarn();
    try {
      (shell as any).handleObserverEvent(
        JSON.stringify({ type: "compact_started", trigger: "manual" }),
      );
      (shell as any).handleObserverEvent(
        JSON.stringify({
          type: "compact_finished",
          trigger: "manual",
          mode: "Replace",
          final_session_id: "s1",
          messages_after: 3,
        }),
      );
      (shell as any).handleObserverEvent(
        JSON.stringify({ type: "operation_finalized", operation: "compact", outcome: "completed", detail: "" }),
      );
      const transcript = transcriptOf(shell);
      expect(transcript).toContain("context compacted (Replace, 3 messages)");
      expect(transcript).not.toContain("unrecognized bridge event");
      expect(warns).toHaveLength(0);
    } finally {
      restore();
    }
  });

  test("a cancelled finalize renders the interrupt exactly once", () => {
    const { shell } = makeShell();
    (shell as any).handleObserverEvent(
      JSON.stringify({ type: "operation_finalized", operation: "compact", outcome: "cancelled", detail: "compact cancelled" }),
    );
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("⏹ compact interrupted");
    expect(transcript.match(/⏹ compact interrupted/g)).toHaveLength(1);
    expect((shell as any).terminationNotices).toBe(1);
  });

  test("a failed finalize renders operation and reason, not a bare label", () => {
    const { shell } = makeShell();
    (shell as any).handleObserverEvent(
      JSON.stringify({
        type: "operation_finalized",
        operation: "compact",
        outcome: "failed",
        detail: "puppet rejected the compact: stage=output, category=missing_output",
      }),
    );
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("compact failed: puppet rejected the compact: stage=output, category=missing_output");
  });

  test("context_state is consumed silently — the statusbar owns its display", () => {
    const { shell } = makeShell();
    const { warns, restore } = captureWarn();
    try {
      expect(
        (shell as any).handleObserverEvent(
          JSON.stringify({ type: "context_state", state: { session_id: "s1" } }),
        ),
      ).toBeUndefined();
      expect(warns).toHaveLength(0);
      expect(transcriptOf(shell)).not.toContain("unrecognized bridge event");
    } finally {
      restore();
    }
  });

  test("a requested interrupt turns turn_failed into a single ⏹ interrupted notice", () => {
    const { shell } = makeShell();
    (shell as any).interruptRequested = true;
    (shell as any).handleObserverEvent(
      JSON.stringify({ type: "turn_failed", error_message: "turn failed: AgentError::Model", error_kind: "Model" }),
    );
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("⏹ interrupted");
    expect(transcript.match(/⏹/g)).toHaveLength(1);
    expect(transcript).not.toContain("turn failed: AgentError::Model");
    expect((shell as any).interruptRequested).toBe(false);
  });

  test("an unrequested turn_failed still renders the router's error notice", () => {
    const { shell } = makeShell();
    (shell as any).handleObserverEvent(
      JSON.stringify({ type: "turn_failed", error_message: "turn failed: AgentError::Session", error_kind: "Session" }),
    );
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("turn failed: AgentError::Session");
    expect(transcript).not.toContain("⏹");
  });
});

describe("/compact command rendering", () => {
  function makeCompactShell(
    invoke: (id: string, args: string) => Promise<string>,
  ): TerminalShell {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      invokeCommand: invoke,
    });
    return shell;
  }

  function transcriptOf(shell: TerminalShell): string {
    return (shell as any).transcript.render(200).join("\n");
  }

  test("success renders the typed summary when no wire finalize fired", async () => {
    const shell = makeCompactShell(async () =>
      JSON.stringify({ type: "success", structured: { ok: true, mode: "Replace", messages_after: 3 } }),
    );
    await (shell as any).runCompactCommand("");
    expect(transcriptOf(shell)).toContain("context compacted (Replace, 3 messages)");
  });

  test("a cancelled compact renders the interrupt from the typed outcome", async () => {
    const shell = makeCompactShell(async () =>
      JSON.stringify({ type: "failure", reason: "compact cancelled", structured: { error_kind: "cancelled" } }),
    );
    await (shell as any).runCompactCommand("");
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("⏹ compact interrupted");
    expect(transcript).not.toContain("/compact failed");
  });

  test("a wire finalize during the command suppresses the outcome display", async () => {
    const shell = makeCompactShell(async () => {
      (shell as any).finalizedOperations += 1;
      return JSON.stringify({ type: "failure", reason: "compact cancelled", structured: { error_kind: "cancelled" } });
    });
    await (shell as any).runCompactCommand("");
    const transcript = transcriptOf(shell);
    expect(transcript).not.toContain("⏹ compact interrupted");
    expect(transcript).not.toContain("/compact failed");
  });

  test("a failing compact surfaces the reason when no finalize event fired", async () => {
    const shell = makeCompactShell(async () =>
      JSON.stringify({ type: "failure", reason: "provider rejected the compact window", structured: { error_kind: "error" } }),
    );
    await (shell as any).runCompactCommand("");
    expect(transcriptOf(shell)).toContain("/compact failed: provider rejected the compact window");
  });

  test("mid-turn compact shows the finalize wait before switching", async () => {
    const shell = makeCompactShell(async () =>
      JSON.stringify({ type: "success", structured: { ok: true, mode: "Replace", messages_after: 1 } }),
    );
    (shell as any).inTurn = true;
    await (shell as any).runCompactCommand("");
    expect(transcriptOf(shell)).toContain(
      "⏸ /compact — waiting for the running operation to finish cleanup",
    );
  });
});
