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

  test("/resume is a local route", () => {
    expect(matchLocalSlash("/resume")?.id).toBe("resume");
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
    // turn_failed without its required fields; the real reason rides along.
    const outcome = parseCetasEventLenient('{"type":"turn_failed"}');
    expect(outcome).toEqual({
      skipped: "malformed turn_failed: turn_failed.error_message must be a string",
    });
    expect(() =>
      parseCetasEventLenient('{"type":"turn_failed"}'),
    ).not.toThrow();
    expect(parseCetasEventLenient('"just a string"')).toEqual({
      skipped: "malformed (no type): cetas event must be an object",
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
  test("skipped events never touch the console; one notice per turn window", () => {
    const { shell } = makeShell();
    const { warns, restore } = captureWarn();
    try {
      (shell as any).handleObserverEvent("{broken");
      (shell as any).handleObserverEvent('{"type":"definitely_new_thing"}');
      // Raw console output corrupts the TUI frame — strictly forbidden.
      expect(warns).toHaveLength(0);
      const transcript = () => (shell as any).transcript.render(200).join("\n");
      const notices = () =>
        transcript().match(/degraded UI event/g) ?? [];
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

  test("the Agent's typed AgentError::Cancelled string marks an interrupt", () => {
    expect(isAbortError("AgentError::Cancelled(turn cancelled)")).toBe(true);
    expect(isAbortError(new Error("AgentError::Cancelled(compact cancelled)"))).toBe(true);
    expect(isAbortError(new Error("AgentError::Runtime(...)"))).toBe(false);
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

  test("a cancelling application operation turns turn_failed into a single ⏹ interrupted notice", () => {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: true,
        phase: "cancelling",
        id: 1,
        kind: "turn",
        interruptible: true,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
    });
    (shell as any).handleObserverEvent(
      JSON.stringify({ type: "turn_failed", error_message: "turn failed: AgentError::Model", error_kind: "Model" }),
    );
    const transcript = transcriptOf(shell);
    expect(transcript).toContain("⏹ interrupted");
    expect(transcript.match(/⏹/g)).toHaveLength(1);
    expect(transcript).not.toContain("turn failed: AgentError::Model");
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
    busy = false,
  ): TerminalShell {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      invokeCommand: invoke,
      operationSnapshot: {
        busy,
        phase: busy ? "running" : "idle",
        ...(busy ? { id: 1, kind: "turn" } : {}),
        interruptible: busy,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
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

  test("mid-turn compact shows the finalize wait from application operation state", async () => {
    const shell = makeCompactShell(
      async () =>
        JSON.stringify({ type: "success", structured: { ok: true, mode: "Replace", messages_after: 1 } }),
      true,
    );
    await (shell as any).runCompactCommand("");
    expect(transcriptOf(shell)).toContain(
      "⏸ /compact — waiting for the running operation to finish cleanup",
    );
  });
});

describe("submit-path pending spinner", () => {
  const snapshot = (state: "ready" | "running") => ({
    state,
    setup: { providers: [], oauthProviders: [] },
    sessionId: "session-1",
  });

  /** Stub application whose started submission parks until the test settles it. */
  function makeTurnStub(): {
    shell: TerminalShell;
    resolveTurn: (value: string) => void;
    rejectTurn: (error: unknown) => void;
  } {
    const { shell } = makeShell();
    let resolveTurn: (value: string) => void = () => {};
    let rejectTurn: (error: unknown) => void = () => {};
    let operation = {
      busy: false,
      phase: "idle",
      interruptible: false,
      followUpsQueued: 0,
      compactPending: false,
      shuttingDown: false,
    } as any;
    const turn = new Promise<string>((resolve, reject) => {
      resolveTurn = resolve;
      rejectTurn = reject;
    });
    const settleReady = () => {
      operation = {
        busy: false,
        phase: "idle",
        interruptible: false,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      };
      (shell as any).handleSnapshot(snapshot("ready"));
    };
    const completion = turn.then(
      (value) => {
        settleReady();
        return value;
      },
      (error) => {
        settleReady();
        throw error;
      },
    );
    (shell as any).attachApplication({
      listCommands: () => [],
      get operationSnapshot() {
        return operation;
      },
      submitUserInput: async () => {
        operation = {
          busy: true,
          phase: "running",
          id: 1,
          kind: "turn",
          interruptible: true,
          followUpsQueued: 0,
          compactPending: false,
          shuttingDown: false,
        };
        (shell as any).handleSnapshot(snapshot("running"));
        return { kind: "started", completion };
      },
    });
    (shell as any).handleSnapshot(snapshot("ready"));
    return { shell, resolveTurn, rejectTurn };
  }

  /** Let submit's awaits reach the application submission boundary. */
  async function flushMicrotasks(ticks = 5): Promise<void> {
    for (let i = 0; i < ticks; i += 1) await Promise.resolve();
  }

  function statusOf(shell: TerminalShell): { count: number; rendered: string } {
    const wrapper = (shell as any).statusWrapper;
    return {
      count: (wrapper.children as unknown[]).length,
      rendered: wrapper.render(80).join("\n"),
    };
  }

  test("the working spinner follows application running state before any wire event", async () => {
    const { shell, resolveTurn } = makeTurnStub();
    const done = shell.submit("hello");
    try {
      await flushMicrotasks();
      expect((shell as any).operationBusy).toBe(true);
      expect(statusOf(shell).count).toBe(1);
      expect(statusOf(shell).rendered).toContain("starting");
    } finally {
      resolveTurn("done");
      await done;
    }
    expect((shell as any).operationBusy).toBe(false);
    expect(statusOf(shell).count).toBe(0);
    expect((shell as any).statusLoader.intervalId).toBeNull();
  });

  test("turn_started swaps the application pending state for thinking without duplicating the status node", async () => {
    const { shell, resolveTurn } = makeTurnStub();
    const done = shell.submit("hello");
    try {
      await flushMicrotasks();
      expect(statusOf(shell).rendered).toContain("starting");
      (shell as any).handleObserverEvent('{"type":"turn_started"}');
      const status = statusOf(shell);
      expect(status.count).toBe(1);
      expect(status.rendered).toContain("thinking");
      expect(status.rendered).not.toContain("starting");
    } finally {
      (shell as any).handleObserverEvent('{"type":"turn_completed"}');
      resolveTurn("done");
      await done;
    }
    expect(statusOf(shell).count).toBe(0);
    expect((shell as any).statusLoader.intervalId).toBeNull();
  });

  test("a bridge rejection clears starting from the application ready transition without a wire failure dependency", async () => {
    const { shell, rejectTurn } = makeTurnStub();
    const done = shell.submit("hello");
    await flushMicrotasks();
    expect(statusOf(shell).count).toBe(1);
    rejectTurn(new Error("bridge exploded"));
    await done;
    expect((shell as any).operationBusy).toBe(false);
    expect(statusOf(shell).count).toBe(0);
    expect((shell as any).statusLoader.intervalId).toBeNull();
    expect((shell as any).transcript.render(200).join("\n")).toContain(
      "bridge exploded",
    );
  });

  test("a host preflight rejection never creates a synthetic starting state", async () => {
    const { shell } = makeShell();
    const loaderBefore = (shell as any).statusLoader.intervalId;
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: true,
        phase: "running",
        id: 7,
        kind: "turn",
        interruptible: true,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
      submitUserInput: async () => {
        throw new Error("a turn is already running");
      },
    });
    await shell.submit("hello");
    expect(statusOf(shell).count).toBe(0);
    // The rejection must not create a new loader lifecycle. Loader's own
    // construction policy is an implementation detail of pi-tui.
    expect((shell as any).statusLoader.intervalId).toBe(loaderBefore);
    expect((shell as any).transcript.render(200).join("\n")).toContain(
      "a turn is already running",
    );
  });

  test("ESC delegates to application cancellation even when no shell-local turn flag exists", () => {
    const { shell } = makeShell();
    let interrupts = 0;
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: true,
        phase: "running",
        id: 9,
        kind: "turn",
        interruptible: true,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
      interruptActiveTurn: () => {
        interrupts += 1;
        return true;
      },
    });
    expect((shell as any).handleInput("\u001b")).toEqual({ consume: true });
    expect(interrupts).toBe(1);
  });
});

describe("command status restore on finish", () => {
  const statusText = (shell: TerminalShell): string =>
    (shell as unknown as { statusLoader: { render(width: number): string[] } }).statusLoader
      .render(80)
      .join("\n");

  test("a finished command restores the turn status while the operation is busy", () => {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: true,
        phase: "running",
        id: 1,
        kind: "turn",
        interruptible: true,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
    });
    (shell as any).setTurnStatus("working", "thinking");
    (shell as any).setCommandStatus("running /permission");
    (shell as any).clearCommandStatus();
    const rendered = statusText(shell);
    expect(rendered).toContain("thinking");
    expect(rendered).not.toContain("running /permission");
  });

  test("a finished command clears the status once the app is settled", () => {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: false,
        phase: "idle",
        interruptible: false,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
    });
    (shell as any).setTurnStatus("working", "thinking");
    (shell as any).setCommandStatus("running /permission");
    (shell as any).clearCommandStatus();
    expect(
      (shell as unknown as { statusWrapper: { children: unknown[] } }).statusWrapper.children,
    ).toHaveLength(0);
  });

  test("a busy operation without a recorded turn status falls back to working", () => {
    const { shell } = makeShell();
    (shell as any).attachApplication({
      listCommands: () => [],
      operationSnapshot: {
        busy: true,
        phase: "running",
        id: 1,
        kind: "turn",
        interruptible: true,
        followUpsQueued: 0,
        compactPending: false,
        shuttingDown: false,
      },
    });
    (shell as any).setCommandStatus("running /permission");
    (shell as any).clearCommandStatus();
    expect(statusText(shell)).toContain("working");
    expect(statusText(shell)).not.toContain("running /permission");
  });
});

describe("surfaceHostFault", () => {
  test("appends the fault notice to the transcript", () => {
    const { shell } = makeShell();
    shell.surfaceHostFault("⚠ host fault (unhandled rejection) logged to /tmp/cetas-js-crash.log");
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("host fault (unhandled rejection)");
    expect(transcript).toContain("/tmp/cetas-js-crash.log");
  });

  test("is a no-op once shutdown has started", async () => {
    const { shell } = makeShell();
    await shell.shutdown();
    const before = (shell as any).transcript.children.length;
    shell.surfaceHostFault("late fault");
    expect((shell as any).transcript.children.length).toBe(before);
  });
});

describe("requestShutdown escalation", () => {
  /** Shell whose attached app never finishes shutting down. */
  function makeHangingShell(forceExitDelayMs: number): {
    shell: TerminalShell;
    exits: number[];
  } {
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
    const exits: number[] = [];
    const shell = new TerminalShell({
      tui,
      cwd: "/tmp",
      sessionsDir,
      maxToolRounds: 8,
      initialSessionId: "2026-09-01T00-00-00-000Z_deadbeef",
      onExit: (code) => exits.push(code),
      forceExitDelayMs,
    });
    (shell as any).attachApplication({
      listCommands: () => [],
      cancelCurrentOperation: () => {},
      shutdown: () => new Promise<void>(() => {}),
    });
    return { shell, exits };
  }

  /** Swap console.error for a recorder; call restore() when done. */
  function captureError(): { errors: string[]; restore(): void } {
    const errors: string[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => {
      errors.push(args.map((item) => String(item)).join(" "));
    };
    return {
      errors,
      restore: () => {
        console.error = original;
      },
    };
  }

  test("a second request while the drain is pending forces the exit", () => {
    const { shell, exits } = makeHangingShell(60_000);
    const captured = captureError();
    try {
      shell.requestShutdown(0);
      expect(exits).toEqual([]);
      shell.requestShutdown(0);
      expect(exits).toEqual([0]);
      expect(captured.errors.join("\n")).toContain("forced by repeated interrupt");
    } finally {
      captured.restore();
    }
  });

  test("the watchdog forces the exit when the graceful drain stalls", async () => {
    const { shell, exits } = makeHangingShell(20);
    const captured = captureError();
    try {
      shell.requestShutdown(0);
      expect(exits).toEqual([]);
      await new Promise((resolve) => setTimeout(resolve, 80));
      expect(exits).toEqual([0]);
      expect(captured.errors.join("\n")).toContain("shutdown timed out");
    } finally {
      captured.restore();
    }
  });
});

/**
 * Core projection customs (frozen posoco.operation/wakeup/tasks/decision)
 * route to their dedicated surfaces and never fall into the generic
 * `· source/label` transcript notice.
 */
describe("core projection events", () => {
  /** Drive one observer event through the shell's lenient parse. */
  function feed(shell: TerminalShell, event: Record<string, unknown>): void {
    (shell as unknown as {
      handleObserverEvent(eventJson: string): void;
    }).handleObserverEvent(JSON.stringify(event));
  }

  function custom(
    source: string,
    label: string,
    data: Record<string, unknown>,
  ): Record<string, unknown> {
    return { type: "custom", source, label, data };
  }

  test("executing wakeups render as an ambient line, never as a transcript notice", () => {
    const { shell } = makeShell();
    feed(
      shell,
      custom("posoco.wakeup", "wakeup_executing", {
        ticket_id: "t1",
        session: "2026-09-01T00-00-00-000Z_deadbeef",
        tag: "build-watch",
        extension_id: "posoco_ext_subagent",
        ticket_enqueued_at: 1,
        envelope: "[posoco-wakeup tag=build-watch] build failed",
      }),
    );
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("wakeup envelope — environment signal");
    expect(transcript).toContain("[posoco-wakeup tag=build-watch] build failed");
    expect(transcript).not.toContain("posoco.wakeup/wakeup_executing");
    // The ambient header (state-driven, so it restores after rebuilds).
    const header = (shell as any).wakeupHeader.render(120).join("\n");
    expect(header).toContain("wakeup build-watch · running (environment)");
    // A repeated executing event neither duplicates the notice nor changes state.
    feed(
      shell,
      custom("posoco.wakeup", "wakeup_executing", {
        ticket_id: "t1",
        session: "2026-09-01T00-00-00-000Z_deadbeef",
        tag: "build-watch",
        extension_id: "posoco_ext_subagent",
        ticket_enqueued_at: 1,
      }),
    );
    const after = (shell as any).transcript.render(200).join("\n");
    expect(after.match(/wakeup envelope — environment signal/g)).toHaveLength(1);
  });

  test("outcome receipts raise the pending-delivery line without transcript noise", () => {
    const { shell } = makeShell();
    feed(
      shell,
      custom("posoco.tasks", "background_outcome_ready", {
        task_id: "task_1",
        session: "2026-09-01T00-00-00-000Z_deadbeef",
        extension_id: "posoco_ext_subagent",
        label: "explore",
        status: "completed",
      }),
    );
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).not.toContain("posoco.tasks/background_outcome_ready");
    const header = (shell as any).wakeupHeader.render(120).join("\n");
    expect(header).toContain("⧗ 1 background result pending delivery");
  });

  test("only decision failures render, bounded and payload-free", () => {
    const { shell } = makeShell();
    feed(
      shell,
      custom("posoco.decision", "decision_failed", {
        call_id: "d1",
        consumer: "posoco_ext_permission",
        provider: "auto_allow",
        purpose: "tool_gate",
        failure_mode: "fail_closed",
        state: "SECRET-REQUEST-BODY",
      }),
    );
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("decision failed");
    expect(transcript).toContain("posoco_ext_permission→auto_allow");
    expect(transcript).toContain("purpose tool_gate");
    expect(transcript).not.toContain("SECRET-REQUEST-BODY");
    expect(transcript).not.toContain("posoco.decision/decision_failed");

    const before = (shell as any).transcript.children.length;
    feed(
      shell,
      custom("posoco.decision", "decision_completed", {
        call_id: "d2",
        consumer: "posoco_ext_permission",
      }),
    );
    expect((shell as any).transcript.children.length).toBe(before);
  });

  test("posoco.operation events stay silent — the application layer owns them", () => {
    const { shell } = makeShell();
    const before = (shell as any).transcript.children.length;
    feed(
      shell,
      custom("posoco.operation", "operation_started", {
        operation_id: "agent_wakeup_w1",
        session: "2026-09-01T00-00-00-000Z_deadbeef",
        origin: "wakeup",
      }),
    );
    expect((shell as any).transcript.children.length).toBe(before);
    expect((shell as any).transcript.render(200)).not.toContain("posoco.operation");
  });

  test("a malformed core projection payload degrades visibly instead of guessing", () => {
    const { shell } = makeShell();
    feed(
      shell,
      custom("posoco.wakeup", "wakeup_executing", {
        session: "s1",
        tag: "no-ticket",
        extension_id: "e",
      }),
    );
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("degraded UI event");
    expect(transcript).toContain("ticket_id");
  });

  test("foreign customs keep the generic notice", () => {
    const { shell } = makeShell();
    feed(shell, custom("posoco.oauth", "progress", { message: "waiting" }));
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("· posoco.oauth/progress");
  });
});

describe("wakeup envelope restore", () => {
  test("a replayed wakeup turn shows the envelope as an environment signal, not user input", () => {
    const { shell } = makeShell();
    // resumeSession repoints the app; a duck-typed double is enough here.
    (shell as any).attachApplication({
      listCommands: () => [],
      setSession: () => {},
    });
    const target = "2026-09-02T00-00-00-000Z_deadbeef";
    writeFileSync(
      join(
        (shell as unknown as { sessionsDir: string }).sessionsDir,
        `${target}.jsonl`,
      ),
      [
        JSON.stringify({ version: 1 }),
        JSON.stringify({
          role: "user",
          content: [{ type: "text", text: "[posoco-wakeup tag=build-watch] build failed" }],
        }),
        JSON.stringify({
          role: "assistant",
          content: [{ type: "text", text: "rebuilt; tests pass." }],
        }),
      ].join("\n") + "\n",
    );
    (shell as unknown as { resumeSession(id: string): void }).resumeSession(target);
    const transcript = (shell as any).transcript.render(200).join("\n");
    expect(transcript).toContain("◌ wakeup envelope");
    expect(transcript).toContain("[posoco-wakeup tag=build-watch] build failed");
  });
});

describe("welcome screen lifecycle", () => {
  test("initial setup is shown in the header and model changes are reflected", () => {
    const { shell } = makeShell();
    const setup = { providers: [], oauthProviders: [] };
    shell.handleSnapshot({ state: "needs_setup", setup, sessionId: "test" });
    expect((shell as any).welcomeHeader.render(88).join("\n")).toContain("/login");
    expect((shell as any).setupStatus.children).toHaveLength(0);
    expect((shell as any).transcript.children).toHaveLength(0);
    shell.handleSnapshot({ state: "ready", sessionId: "test", setup: {
      ...setup, activeModelId: "test-model", providers: [{
        id: "test-model", label: "Chosen model", provider: "test", model: "model",
        active: true, efforts: [], oauth: false,
      }],
    } });
    expect((shell as any).welcomeHeader.render(88).join("\n")).toContain("Chosen model");
  });

  test("only accepted prompts collapse the welcome; a new session restores it", async () => {
    const { shell } = makeShell();
    const ui = shell as any;
    const echo = { render: () => [], invalidate: () => {} };
    await ui.submitApplicationInput({ submitUserInput: async () => { throw new Error("not configured"); } }, "hi", "hi", echo);
    expect(ui.welcomeHeader.compact).toBe(false);
    await ui.submitApplicationInput({ submitUserInput: async () => ({ kind: "full" }) }, "hi", "hi", echo);
    expect(ui.welcomeHeader.compact).toBe(false);
    await ui.submitApplicationInput({ submitUserInput: async () => ({ kind: "started", completion: Promise.resolve("") }) }, "hi", "hi", echo);
    expect(ui.welcomeHeader.compact).toBe(true);
    let next = "";
    ui.attachApplication({ listCommands: () => [], setSession: (id: string) => { next = id; } });
    await ui.startNewSession();
    expect(next).not.toBe("");
    expect(ui.transcript.children).toHaveLength(0);
    expect(ui.welcomeHeader.compact).toBe(false);
  });
});
