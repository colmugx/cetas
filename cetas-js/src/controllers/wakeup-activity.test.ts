import { describe, expect, test } from "bun:test";

import type { CoreWakeupEvent } from "../core-events.ts";
import { WakeupActivityStore } from "./wakeup-activity.ts";

function wakeupEvent(overrides: Partial<CoreWakeupEvent> = {}): CoreWakeupEvent {
  return {
    state: "requested",
    ticket_id: "t1",
    session: "s1",
    tag: "build-watch",
    extension_id: "posoco_ext_subagent",
    enqueued_at: 42,
    ...overrides,
  };
}

describe("WakeupActivityStore", () => {
  test("walks the seven-state lifecycle and keeps the envelope", () => {
    const store = new WakeupActivityStore();
    expect(store.apply(wakeupEvent())).toBe(true);
    expect(store.apply(wakeupEvent({ state: "executing", envelope: "env" }))).toBe(true);
    const ticket = store.get("t1");
    expect(ticket).toMatchObject({ state: "executing", envelope: "env", tag: "build-watch" });
    expect(store.executing("s1")).toHaveLength(1);
    expect(store.apply(wakeupEvent({ state: "completed", operation_id: "op_1" }))).toBe(true);
    expect(store.executing("s1")).toHaveLength(0);
    expect(store.get("t1")).toMatchObject({ state: "completed", operation_id: "op_1" });
  });

  test("one terminal per ticket: later events never revive it", () => {
    const store = new WakeupActivityStore();
    store.apply(wakeupEvent());
    store.apply(wakeupEvent({ state: "cancelled" }));
    expect(store.apply(wakeupEvent({ state: "executing", envelope: "late" }))).toBe(false);
    expect(store.get("t1")?.state).toBe("cancelled");
    expect(store.get("t1")?.envelope).toBeUndefined();
  });

  test("satisfied is a terminal, not an executing state", () => {
    const store = new WakeupActivityStore();
    store.apply(wakeupEvent());
    store.apply(wakeupEvent({ state: "satisfied" }));
    expect(store.executing("s1")).toHaveLength(0);
    expect(store.apply(wakeupEvent({ state: "executing" }))).toBe(false);
  });

  test("executing queries scope by owner session", () => {
    const store = new WakeupActivityStore();
    store.apply(wakeupEvent({ ticket_id: "a", session: "s1", state: "executing" }));
    store.apply(
      wakeupEvent({ ticket_id: "b", session: "s2", tag: "cron", state: "executing" }),
    );
    expect(store.executing("s1").map((t) => t.ticket_id)).toEqual(["a"]);
    expect(store.executing()).toHaveLength(2);
  });

  test("a re-request during execution forms a new pending ticket", () => {
    const store = new WakeupActivityStore();
    store.apply(wakeupEvent({ ticket_id: "t1" }));
    store.apply(wakeupEvent({ ticket_id: "t1", state: "executing" }));
    store.apply(wakeupEvent({ ticket_id: "t2" }));
    expect(store.executing("s1").map((t) => t.ticket_id)).toEqual(["t1"]);
    expect(store.get("t2")).toMatchObject({ state: "requested" });
  });

  test("clear drops every ticket", () => {
    const store = new WakeupActivityStore();
    store.apply(wakeupEvent());
    store.clear();
    expect(store.get("t1")).toBeUndefined();
    expect(store.executing()).toHaveLength(0);
  });
});
