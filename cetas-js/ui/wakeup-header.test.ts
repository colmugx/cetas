/**
 * wakeup-header.test.ts — the ambient header projection: pending-delivery
 * wording, the ready → delivered transition clearing the line, and the
 * wakeup lines rendered alongside.
 */

import { describe, expect, it } from "bun:test";

import { parseCetasEvent } from "../src/events.ts";
import { SubagentActivityStore } from "../src/controllers/subagent-activity.ts";
import type { WakeupTicket } from "../src/controllers/wakeup-activity.ts";
import { renderWakeupHeader, wakeupHeaderLines } from "./wakeup-header.ts";

const NO_TICKETS: readonly WakeupTicket[] = [];

function ticket(tag: string): WakeupTicket {
  return {
    ticket_id: `t-${tag}`,
    session: "s1",
    tag,
    extension_id: "posoco_ext_subagent",
    state: "executing",
    enqueued_at: 1,
  };
}

/** One parsed extension `background_delivered` ack for a task id. */
function deliveredAck(taskId: string) {
  return parseCetasEvent({
    type: "subagent_event",
    child_session: "bg",
    kind: "coder",
    parent_call: "background",
    ev: {
      type: "custom",
      source: "posoco_ext_subagent",
      label: "background_delivered",
      data: { task_id: taskId },
    },
  })!;
}

describe("wakeupHeaderLines", () => {
  it("words the pending-delivery line and pluralizes", () => {
    expect(wakeupHeaderLines({ executing: NO_TICKETS, resultsWaiting: 1 })).toEqual([
      "⧗ 1 background result pending delivery",
    ]);
    expect(wakeupHeaderLines({ executing: NO_TICKETS, resultsWaiting: 2 })).toEqual([
      "⧗ 2 background results pending delivery",
    ]);
    // Nothing pending and nothing executing: the header renders nothing.
    expect(wakeupHeaderLines({ executing: NO_TICKETS, resultsWaiting: 0 })).toEqual([]);
    expect(renderWakeupHeader({ executing: NO_TICKETS, resultsWaiting: 0 }, 120)).toEqual(
      [],
    );
  });

  it("renders executing wakeup lines alongside the pending-delivery line", () => {
    expect(
      wakeupHeaderLines({ executing: [ticket("build-watch")], resultsWaiting: 1 }),
    ).toEqual([
      "⧗ 1 background result pending delivery",
      "◌ wakeup build-watch · running (environment)",
    ]);
  });
});

describe("wakeup header ready → delivered", () => {
  it("raises the line when a receipt arrives and clears it on the ack", () => {
    const store = new SubagentActivityStore();
    const header = () => {
      const resultsWaiting = store.resultsWaiting("s1");
      return wakeupHeaderLines({ executing: NO_TICKETS, resultsWaiting });
    };
    // Core receipt: the outcome is queued, not yet injected.
    expect(store.noteOutcomeReady("task_1", "s1")).toBe(true);
    expect(header()).toEqual(["⧗ 1 background result pending delivery"]);
    // The extension's delivery ack closes the receipt by task id.
    expect(store.apply(deliveredAck("task_1"))).toBe(true);
    expect(store.resultsWaiting("s1")).toBe(0);
    expect(header()).toEqual([]);
  });

  it("duplicate acks keep the header cleared and other sessions unaffected", () => {
    const store = new SubagentActivityStore();
    store.noteOutcomeReady("task_1", "s1");
    store.apply(deliveredAck("task_1"));
    // A repeated ack is a no-op; the header stays empty.
    expect(store.apply(deliveredAck("task_1"))).toBe(false);
    expect(store.resultsWaiting("s1")).toBe(0);
    // A result waiting for another session never leaks into this header.
    store.noteOutcomeReady("task_2", "s2");
    expect(store.resultsWaiting("s1")).toBe(0);
    expect(store.resultsWaiting("s2")).toBe(1);
  });
});
