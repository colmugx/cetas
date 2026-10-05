import { describe, expect, it } from "bun:test";

import { parseCetasEvent } from "../events.ts";
import {
  argsPreview,
  SUBAGENT_NAME_WORDS,
  SubagentActivityStore,
  type SubagentActivity,
} from "./subagent-activity.ts";

/** Build one parsed `subagent_event` from a raw child turn event. */
function childEvent(
  childSession: string,
  parentCall: string,
  inner: Record<string, unknown>,
) {
  return parseCetasEvent({
    type: "subagent_event",
    child_session: childSession,
    kind: "coder",
    parent_call: parentCall,
    ev: inner,
  })!;
}

/** Lifecycle announcement: `spawned` rides the real spawning call id. */
function spawned(
  store: SubagentActivityStore,
  childSession: string,
  parentCall: string,
  data: Record<string, unknown> = { model: "m/v", effort: "high", background: false },
) {
  return store.apply(
    childEvent(childSession, parentCall, {
      type: "custom",
      source: "posoco_ext_subagent",
      label: "spawned",
      data,
    }),
  );
}

function label(
  store: SubagentActivityStore,
  childSession: string,
  name: string,
  data: Record<string, unknown>,
) {
  return store.apply(
    childEvent(childSession, "background", {
      type: "custom",
      source: "posoco_ext_subagent",
      label: name,
      data,
    }),
  );
}

describe("SubagentActivityStore", () => {
  it("ignores non-subagent events", () => {
    const store = new SubagentActivityStore();
    expect(
      store.apply(parseCetasEvent({ type: "turn_started" })!),
    ).toBe(false);
    expect(store.all().length).toBe(0);
  });

  it("tracks steps, current tool, and terminal state", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("subagent-1", "call_9", { type: "turn_started" }));
    store.apply(
      childEvent("subagent-1", "call_9", {
        type: "tool_call_started",
        tool_call_id: "t1",
        tool_name: "grep",
        args: { pattern: "todo" },
      }),
    );
    store.apply(
      childEvent("subagent-1", "call_9", {
        type: "tool_call_completed",
        tool_call_id: "t1",
        result: "ok",
        is_error: false,
      }),
    );
    store.apply(childEvent("subagent-1", "call_9", { type: "turn_completed" }));

    const record = store.get("subagent-1")!;
    expect(record.kind).toBe("coder");
    expect(record.parent_call).toBe("call_9");
    expect(record.steps).toBe(1);
    expect(record.status).toBe("completed");
    expect(record.current_tool).toBeUndefined();
    expect(record.last_tool).toBe("grep");
    expect(record.version).toBeGreaterThan(0);
  });

  it("keeps a text tail from stream chunks", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("s", "c", { type: "turn_started" }));
    store.apply(
      childEvent("s", "c", {
        type: "stream_chunk",
        raw: "reading the router",
        kind: "text",
      }),
    );
    expect(store.get("s")!.text_tail).toContain("reading the router");
  });

  it("apply() only reports real changes", () => {
    const store = new SubagentActivityStore();
    expect(store.apply(childEvent("s", "c", { type: "turn_started" }))).toBe(true);
    // Empty token adds nothing to the tail.
    expect(
      store.apply(childEvent("s", "c", { type: "stream_chunk", raw: "", kind: "text" })),
    ).toBe(false);
    // Unrelated extension labels and unknown labels never mutate.
    expect(
      store.apply(
        childEvent("s", "c", {
          type: "custom",
          source: "some_other_extension",
          label: "spawned",
          data: {},
        }),
      ),
    ).toBe(false);
    expect(
      store.apply(
        childEvent("s", "c", {
          type: "custom",
          source: "posoco_ext_subagent",
          label: "mystery_label",
          data: {},
        }),
      ),
    ).toBe(false);
    const version = store.get("s")!.version;
    expect(store.get("s")!.version).toBe(version);
  });

  it("same-call turn starts never revive a finished run; a new call does", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("s", "call_1", { type: "turn_started" }));
    store.apply(
      childEvent("s", "call_1", {
        type: "turn_failed",
        error_message: "boom",
        error_kind: "model",
      }),
    );
    const failed = store.get("s")!;
    expect(failed.status).toBe("failed");
    expect(failed.error).toBe("boom");

    // Stale replay of the finished run's own turn must not resurrect it.
    const version = failed.version;
    expect(store.apply(childEvent("s", "call_1", { type: "turn_started" }))).toBe(false);
    expect(store.get("s")!.status).toBe("failed");
    expect(store.get("s")!.version).toBe(version);

    // Lifecycle labels report parent_call="background"; never rekey off them.
    label(store, "s", "background_spawned", {});
    expect(store.get("s")!.parent_call).toBe("call_1");

    // A genuinely new parent call reactivates the record as a new run.
    expect(store.apply(childEvent("s", "call_2", { type: "turn_started" }))).toBe(true);
    const resumed = store.get("s")!;
    expect(resumed.status).toBe("running");
    expect(resumed.parent_call).toBe("call_2");
    expect(resumed.run_id).toBe("call_2");
    expect(resumed.error).toBeUndefined();
    expect(resumed.steps).toBe(1);
  });

  it("runningForParentCall finds the live child of a parent call", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("s1", "call_a", { type: "turn_started" }));
    store.apply(childEvent("s1", "call_a", { type: "turn_completed" }));
    store.apply(childEvent("s2", "call_a", { type: "turn_started" }));
    expect(store.runningForParentCall("call_a")!.child_session).toBe("s2");
    expect(store.runningForParentCall("call_missing")).toBeUndefined();
  });

  it("argsPreview truncates long strings and skips complex values", () => {
    const preview = argsPreview({
      pattern: "x".repeat(300),
      limit: 5,
      nested: { a: 1 },
    });
    expect(preview).toContain("pattern=xxx");
    expect(preview).toContain("limit=5");
    expect(preview).not.toContain("nested");
  });

  it("records model/effort/background from spawned and converges terminal once", () => {
    const store = new SubagentActivityStore();
    spawned(store, "s9", "background", {
      model: "deepseek/deepseek-v4-flash",
      effort: "high",
      background: true,
    });
    label(store, "s9", "background_spawned", { task_id: "task_1" });
    let record = store.get("s9")!;
    expect(record.model).toBe("deepseek/deepseek-v4-flash");
    expect(record.effort).toBe("high");
    expect(record.background).toBe(true);
    expect(record.task_id).toBe("task_1");
    expect(record.status).toBe("running");

    expect(
      label(store, "s9", "background_terminal", {
        state: "completed",
        summary: "done deal",
      }),
    ).toBe(true);
    // Duplicate authoritative terminals never mutate again.
    expect(
      label(store, "s9", "background_terminal", {
        state: "completed",
        summary: "done deal",
      }),
    ).toBe(false);
    record = store.get("s9")!;
    expect(record.status).toBe("completed");
    expect(record.summary).toBe("done deal");
    expect(record.terminal_received).toBe(true);
    expect(record.terminal_state).toBe("completed");

    const notice = store.claimTerminalNotification("s9")!;
    expect(notice.display_name).toBe(record.display_name);
    expect(notice.terminal_state).toBe("completed");
    expect(notice.success).toBe(true);
    expect(notice.summary).toBe("done deal");
    expect(notice.task_id).toBe("task_1");
    // Claiming is once-per-run.
    expect(store.claimTerminalNotification("s9")).toBeUndefined();
  });

  it("keeps a bounded step history (steps + tool calls), oldest first", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("s", "c", { type: "turn_started" }));
    store.apply(
      childEvent("s", "c", {
        type: "tool_call_started",
        tool_call_id: "t1",
        tool_name: "read",
        args: { path: "src/main.ts" },
      }),
    );
    store.apply(
      childEvent("s", "c", {
        type: "tool_call_completed",
        tool_call_id: "t1",
        result: "ok",
        is_error: false,
      }),
    );
    store.apply(
      childEvent("s", "c", {
        type: "turn_failed",
        error_message: "kaboom\nwith detail",
        error_kind: "model",
      }),
    );
    const history = store.get("s")!.history;
    expect(history.length).toBe(3);
    expect(history[0]).toBe("▸ step 1");
    expect(history[1]).toContain("▸ read path=src/main.ts");
    expect(history[2]).toBe("✗ kaboom with detail");
  });

  it("running() drops terminal children", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("s1", "c1", { type: "turn_started" }));
    store.apply(childEvent("s2", "c2", { type: "turn_started" }));
    store.apply(childEvent("s2", "c2", { type: "turn_completed" }));
    expect(store.running().map((r) => r.child_session)).toEqual(["s1"]);
  });

  it("uses the injected clock for run starts", () => {
    let clock = 1_000;
    const store = new SubagentActivityStore(() => clock);
    spawned(store, "s", "call_1");
    expect(store.get("s")!.started_at).toBe(1_000);
    clock = 9_500;
    // A changed spawn call opens a new run with a fresh start time.
    spawned(store, "s", "call_2");
    expect(store.get("s")!.started_at).toBe(9_500);
    expect(store.get("s")!.run_id).toBe("call_2");
  });

  it("repeated spawns of the same call are idempotent", () => {
    let clock = 1_000;
    const store = new SubagentActivityStore(() => clock);
    spawned(store, "s", "call_1");
    store.apply(childEvent("s", "call_1", { type: "turn_started" }));
    const before = store.get("s")!;
    clock = 5_000;
    expect(spawned(store, "s", "call_1")).toBe(false);
    const after = store.get("s")!;
    expect(after.started_at).toBe(before.started_at);
    expect(after.steps).toBe(before.steps);
    expect(after.version).toBe(before.version);
  });

  it("background children only join the running list once accepted", () => {
    const store = new SubagentActivityStore();
    // Refused/unaccepted background spawns leave no forever-running header.
    spawned(store, "bg", "call_bg", { background: true });
    expect(store.running().length).toBe(0);
    expect(store.runningBackground().length).toBe(0);
    label(store, "bg", "background_spawned", { task_id: "task_bg" });
    expect(store.runningBackground().length).toBe(1);
  });

  it("background child turns end the child turn, not the background work", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "call_bg", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_bg" });
    store.apply(childEvent("bg", "call_bg", { type: "turn_started" }));
    store.apply(childEvent("bg", "call_bg", { type: "turn_completed" }));

    let record = store.get("bg")!;
    expect(record.child_turn_state).toBe("completed");
    expect(record.status).toBe("running");
    expect(store.runningBackground().length).toBe(1);

    // A failed child turn is recorded but also does not end the run.
    store.apply(childEvent("bg", "call_bg", { type: "turn_started" }));
    store.apply(
      childEvent("bg", "call_bg", {
        type: "turn_failed",
        error_message: "child blew up",
        error_kind: "model",
      }),
    );
    record = store.get("bg")!;
    expect(record.child_turn_state).toBe("failed");
    expect(record.error).toBe("child blew up");
    expect(record.status).toBe("running");
    expect(store.runningBackground().length).toBe(1);
  });

  it("exit removes running eligibility and keeps the raw word; terminal is authoritative", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "call_bg", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_bg" });

    // Actual exit: best-effort word preserved verbatim, immediately not running.
    label(store, "bg", "background_exited", { state: "cancelled", detail: "cancelled" });
    let record = store.get("bg")!;
    expect(record.exited).toBe(true);
    expect(record.terminal_state).toBe("cancelled");
    expect(record.status).toBe("failed");
    expect(store.runningBackground().length).toBe(0);

    // Authoritative terminal corrects the classification, keeps the raw word.
    label(store, "bg", "background_terminal", {
      state: "timed_out",
      summary: "ran out of time",
    });
    record = store.get("bg")!;
    expect(record.terminal_received).toBe(true);
    expect(record.terminal_state).toBe("timed_out");
    expect(record.summary).toBe("ran out of time");

    const notice = store.claimTerminalNotification("bg")!;
    expect(notice.terminal_state).toBe("timed_out");
    expect(notice.success).toBe(false);
  });

  it("an unknown terminal word is preserved verbatim and never guessed as failure", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "call_bg", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_bg" });
    label(store, "bg", "background_terminal", { state: "warp_field_failure" });
    const record = store.get("bg")!;
    expect(record.terminal_received).toBe(true);
    expect(record.terminal_state).toBe("warp_field_failure");
    // Unknown classification: keep the prior coarse state, but the run is over.
    expect(record.status).toBe("running");
    expect(store.runningBackground().length).toBe(0);
  });

  it("a late exit cannot overwrite an authoritative terminal", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "call_bg", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_bg" });
    label(store, "bg", "background_terminal", {
      state: "completed",
      summary: "authoritative",
    });
    expect(
      label(store, "bg", "background_exited", { state: "failed", detail: "late" }),
    ).toBe(false);
    const record = store.get("bg")!;
    expect(record.terminal_state).toBe("completed");
    expect(record.summary).toBe("authoritative");
  });

  it("notifications dedupe per run: resume with a new spawn notifies again", () => {
    let clock = 1_000;
    const store = new SubagentActivityStore(() => clock);
    spawned(store, "bg", "call_1", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_1" });
    label(store, "bg", "background_terminal", { state: "completed", summary: "first" });
    expect(store.claimTerminalNotification("bg")!.summary).toBe("first");
    expect(store.claimTerminalNotification("bg")).toBeUndefined();

    clock = 2_000;
    // Resume: new spawn call opens a new run and re-arms notification.
    spawned(store, "bg", "call_2", { background: true });
    expect(store.get("bg")!.task_id).toBeUndefined();
    label(store, "bg", "background_spawned", { task_id: "task_2" });
    label(store, "bg", "background_terminal", { state: "failed", summary: "second" });
    const notice = store.claimTerminalNotification("bg")!;
    expect(notice.summary).toBe("second");
    expect(notice.task_id).toBe("task_2");
    expect(notice.run_id).toBe("call_2");
  });

  it("assigns stable unique nicknames in order; resumes keep theirs", () => {
    const store = new SubagentActivityStore();
    spawned(store, "a", "call_a");
    spawned(store, "b", "call_b");
    spawned(store, "c", "call_c");
    expect(store.get("a")!.display_name).toBe("apple");
    expect(store.get("b")!.display_name).toBe("banana");
    expect(store.get("c")!.display_name).toBe("cherry");

    // Resume under a new call keeps the name.
    spawned(store, "a", "call_a2");
    expect(store.get("a")!.display_name).toBe("apple");

    // Exhausting the word list falls back to unique numeric suffixes.
    const total = SUBAGENT_NAME_WORDS.length + 2;
    for (let index = 0; index < total; index += 1) {
      spawned(store, `kid-${index}`, `call-kid-${index}`);
    }
    const names = new Set(
      store.all().map((record) => record.display_name),
    );
    expect(names.size).toBe(total + 3);
    expect(names.has("apple-2")).toBe(true);
    // Stable appearance order for display.
    const ordered = store.all().map((record) => record.seq);
    expect([...ordered].sort((x, y) => x - y)).toEqual(ordered);
  });

  it("tags records with the owning session and filters by it", () => {
    const store = new SubagentActivityStore();
    store.setOwnerSession("sess-A");
    spawned(store, "a", "call_a", { background: true });
    label(store, "a", "background_spawned", { task_id: "task_a" });
    expect(store.get("a")!.owner_session).toBe("sess-A");
    expect(store.running("sess-B")).toEqual([]);

    // Per-event scope overrides the store default for new records.
    store.apply(childEvent("b", "call_b", { type: "turn_started" }), "sess-B");
    expect(store.get("b")!.owner_session).toBe("sess-B");
    expect(store.running("sess-A").map((r) => r.child_session)).toEqual(["a"]);

    label(store, "a", "background_terminal", { state: "completed" });
    // A foreign session cannot claim another session's notification.
    expect(store.claimTerminalNotification("a", "sess-B")).toBeUndefined();
    expect(store.claimTerminalNotification("a", "sess-A")).toBeDefined();
  });

  it("does not create records from unrelated first events", () => {
    const store = new SubagentActivityStore();
    expect(
      store.apply(
        childEvent("x", "c", { type: "model_invoked", model: "m" }),
      ),
    ).toBe(false);
    expect(store.get("x")).toBeUndefined();
  });
});

describe("SubagentActivityStore outcome receipts", () => {
  it("counts ready-but-undelivered receipts per owner session", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "background", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_1" });
    expect(store.resultsWaiting("s1")).toBe(0);

    expect(store.noteOutcomeReady("task_1", "s1")).toBe(true);
    expect(store.resultsWaiting("s1")).toBe(1);
    // Duplicate receipts are no-ops.
    expect(store.noteOutcomeReady("task_1", "s1")).toBe(false);
    expect(store.resultsWaiting("s1")).toBe(1);
    // Session scoping: another session sees nothing waiting.
    expect(store.resultsWaiting("s2")).toBe(0);
  });

  it("the authoritative terminal delivers the receipt; an exit alone does not", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "background", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_1" });
    store.noteOutcomeReady("task_1", "s1");
    label(store, "bg", "background_exited", { state: "completed" });
    expect(store.resultsWaiting("s1")).toBe(1);
    label(store, "bg", "background_terminal", { state: "completed", summary: "done" });
    expect(store.resultsWaiting("s1")).toBe(0);
  });

  it("receipts for unobserved tasks keep waiting", () => {
    const store = new SubagentActivityStore();
    store.noteOutcomeReady("lost_task", "s1");
    expect(store.resultsWaiting("s1")).toBe(1);
  });

  it("flags the matching record and bumps its version once", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "background", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_1" });
    const before = store.get("bg")!.version;
    store.noteOutcomeReady("task_1", "s1");
    expect(store.get("bg")!.outcome_ready).toBe(true);
    expect(store.get("bg")!.version).toBe(before + 1);
    store.noteOutcomeReady("task_1", "s1");
    expect(store.get("bg")!.version).toBe(before + 1);
  });
});

describe("SubagentActivityStore snapshot shape", () => {
  it("exposes the fields the header and shell project", () => {
    const store = new SubagentActivityStore();
    spawned(store, "bg", "call_bg", { background: true });
    label(store, "bg", "background_spawned", { task_id: "task_bg" });
    const record: SubagentActivity = store.get("bg")!;
    expect(record.display_name.length).toBeGreaterThan(0);
    expect(record.seq).toBeGreaterThanOrEqual(0);
    expect(record.terminal_notified).toBe(false);
  });
});
