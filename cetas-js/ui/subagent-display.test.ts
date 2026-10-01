import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { TuiMainScreen, type Terminal } from "@earendil-works/pi-tui";
import { TerminalShell } from "./terminal-shell.ts";

const nativeInterval = globalThis.setInterval;
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function harness(rows = 12) {
  const writes: string[] = [];
  const ticks: Array<() => void> = [];
  const intervals: ReturnType<typeof setInterval>[] = [];
  const children: Array<{ id: string; parent: string }> = [];
  const intervalSpy = spyOn(globalThis, "setInterval").mockImplementation(
    ((handler: (...args: unknown[]) => void, delay?: number, ...args: unknown[]) => {
      if (delay === 1000) ticks.push(() => handler(...args));
      const handle = nativeInterval(handler, delay, ...args);
      intervals.push(handle);
      return handle;
    }) as typeof setInterval,
  );
  const terminal: Terminal = {
    columns: 100,
    rows,
    kittyProtocolActive: false,
    start: () => {},
    stop: () => {},
    drainInput: async () => {},
    write: (data) => { writes.push(data); },
    moveBy: () => {},
    hideCursor: () => {},
    showCursor: () => {},
    clearLine: () => {},
    clearFromCursor: () => {},
    clearScreen: () => {},
    setTitle: () => {},
    setProgress: () => {},
  };
  const tui = new TuiMainScreen(terminal);
  const shell = new TerminalShell({
    tui,
    cwd: ".",
    sessionsDir: "test_fixtures",
    initialSessionId: "display-session",
    maxToolRounds: 8,
  });
  const send = (ev: object) => shell.callbacks.observerCallback(JSON.stringify(ev));
  const child = (id: string, parent: string, ev: object) => send({
    type: "subagent_event", child_session: id, parent_call: parent, kind: "coder", ev,
  });
  const spawn = (id: string, parent = `call-${id}`, background = true) => {
    children.push({ id, parent });
    child(id, parent, {
      type: "custom", source: "posoco_ext_subagent", label: "spawned",
      data: { model: "test/model", effort: "high", background },
    });
    if (background) child(id, "background", {
      type: "custom", source: "posoco_ext_subagent", label: "background_spawned",
      data: { task_id: `task-${id}-${parent}` },
    });
    child(id, parent, { type: "turn_started" });
  };
  const custom = (id: string, label: string, data: object) => child(id, "background", {
    type: "custom", source: "posoco_ext_subagent", label, data,
  });
  const body = (lines = 25) => {
    send({ type: "stream_chunk", kind: "text", raw:
      Array.from({ length: lines }, (_,i) => `PARENT_BODY_${i}`).join("\n\n"),
    });
    send({ type: "message_end", message: {
      role: "assistant", content: [{ type: "text", text: "already streamed" }],
    } });
  };
  const flush = () => tui.renderNow();
  const visible = () => tui.render(terminal.columns).join("\n");
  cleanups.push(async () => {
    for (const { id, parent } of children) {
      child(id, parent, { type: "turn_completed" });
      custom(id, "background_terminal", { state: "completed", summary: "" });
      send({ type: "tool_call_completed", tool_call_id: parent, result: "done", is_error: false });
    }
    send({ type: "turn_completed" });
    await shell.shutdown();
    for (const interval of intervals) clearInterval(interval);
    intervalSpy.mockRestore();
    tui.stop({ preserveScreen: true });
  });
  return { shell, tui, terminal, writes, send, child, spawn, custom, body, flush, visible,
    tick: () => { for (const tick of ticks) tick(); },
    reset: () => { writes.length = 0; },
  };
}

function expectLocalUpdate(h: ReturnType<typeof harness>, previousRedraws: number) {
  expect(h.tui.fullRedraws).toBe(previousRedraws);
  expect(h.writes.join("")).not.toContain("PARENT_BODY_0");
  expect(h.writes.join("")).not.toContain("\x1b[3J");
}

describe("subagent display — real pi-tui output", () => {
  test("background progress only updates the header after parent history has grown", () => {
    const h = harness();
    h.send({ type: "turn_started" });
    h.spawn("background-local");
    h.body();
    h.flush();
    const before = h.tui.fullRedraws;
    h.reset();
    h.child("background-local", "call-background-local", {
      type: "tool_call_started", tool_call_id: "bash-1", tool_name: "bash", args: { cmd: "echo hi" },
    });
    h.flush();
    expectLocalUpdate(h, before);
    expect(h.visible()).not.toContain("🛰");
    expect(h.visible()).toContain("agent(apple)");
    expect(h.visible()).toContain("bash");
  });

  test("elapsed ticks do not replay a long parent transcript", () => {
    const now = spyOn(Date, "now").mockReturnValue(100_000);
    cleanups.push(async () => { now.mockRestore(); });
    const h = harness();
    h.send({ type: "turn_started" });
    h.spawn("elapsed");
    h.body();
    h.flush();
    const before = h.tui.fullRedraws;
    h.reset();
    now.mockReturnValue(153_000);
    h.tick();
    h.flush();
    expectLocalUpdate(h, before);
    expect(h.visible()).toContain("53s");
  });

  test("child turn end is not background exit and terminal notification is emitted once", () => {
    const h = harness(30);
    h.spawn("terminal");
    h.child("terminal", "call-terminal", { type: "turn_completed" });
    expect(h.visible()).toContain("⚡");
    h.custom("terminal", "background_exited", { state: "cancelled", detail: "cancelled" });
    expect(h.visible()).not.toContain("⚡");
    h.custom("terminal", "background_terminal", { state: "timed_out", summary: "display-final-marker" });
    h.custom("terminal", "background_terminal", { state: "timed_out", summary: "display-final-marker" });
    expect(h.visible().split("display-final-marker").length - 1).toBe(1);
    expect(h.visible()).toContain("timed_out");
    h.child("terminal", "call-terminal", {
      type: "custom", source: "unrelated-extension", label: "late", data: {},
    });
    expect(h.visible()).not.toContain("⚡");
  });

  test("a foreground child late event never becomes a background transcript row", () => {
    const h = harness(30);
    h.send({ type: "turn_started" });
    h.send({ type: "tool_call_started", tool_call_id: "fg-call", tool_name: "agent", args: { kind: "coder" } });
    h.spawn("foreground-late", "fg-call", false);
    h.send({ type: "tool_call_completed", tool_call_id: "fg-call", result: "finished", is_error: false });
    const before = h.visible();
    h.child("foreground-late", "fg-call", { type: "turn_completed" });
    expect(h.visible()).toBe(before);
    expect(h.visible()).not.toContain("🛰");
  });

  test("offscreen foreground progress and ticks do not replay parent history", () => {
    const now = spyOn(Date, "now").mockReturnValue(100_000);
    cleanups.push(async () => { now.mockRestore(); });
    const h = harness();
    h.send({ type: "turn_started" });
    h.send({ type: "tool_call_started", tool_call_id: "fg-a", tool_name: "agent", args: { kind: "coder" } });
    h.spawn("fg-a-child", "fg-a", false);
    h.send({ type: "tool_call_started", tool_call_id: "fg-b", tool_name: "agent", args: { kind: "coder" } });
    h.spawn("fg-b-child", "fg-b", false);
    h.body();
    h.flush();
    const before = h.tui.fullRedraws;
    h.reset();
    h.child("fg-a-child", "fg-a", {
      type: "stream_chunk", raw: "offscreen-child-token", kind: "text",
    });
    now.mockReturnValue(153_000);
    h.tick();
    h.flush();
    expectLocalUpdate(h, before);
    expect(h.visible()).not.toContain("offscreen-child-token");
  });

  test("visible foreground card keeps model, effort, tool and text tail", () => {
    const h = harness(40);
    h.send({ type: "turn_started" });
    h.send({ type: "tool_call_started", tool_call_id: "visible-fg", tool_name: "agent", args: { kind: "coder" } });
    h.spawn("visible-child", "visible-fg", false);
    h.flush();
    h.child("visible-child", "visible-fg", {
      type: "tool_call_started", tool_call_id: "r1", tool_name: "read", args: { path: "src/main.ts" },
    });
    h.child("visible-child", "visible-fg", { type: "stream_chunk", raw: "foreground-tail", kind: "text" });
    h.flush();
    expect(h.visible()).toContain("test/model(high)");
    expect(h.visible()).toContain("step 1");
    expect(h.visible()).toContain("read");
    expect(h.visible()).toContain("foreground-tail");
    expect(h.visible()).not.toContain("⚡");
  });

  test("two shells do not share background activity or naming", () => {
    const first = harness(30);
    first.spawn("first-child");
    const second = harness(30);
    second.spawn("second-child");
    expect(second.visible()).toContain("agent(apple)");
    expect(second.visible()).not.toContain("agent(banana)");
    expect(second.visible()).not.toContain("2 agents");
    expect(first.visible()).not.toContain("second-child");
  });
});
