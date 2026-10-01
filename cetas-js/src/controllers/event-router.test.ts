/**
 * event-router.test.ts — session_redirect follow-through, the late
 * tool_call_completed status guard, and the live subagent row refresh
 * (refreshSubagentRow / refreshRunningSubagents + streaming adoption).
 *
 * Pattern mirrors tool-streaming.test.ts: real pi-tui Container + a plain
 * callbacks record, asserted via render substring checks and callback spies.
 */

import { describe, expect, test } from "bun:test";
import { Container } from "@earendil-works/pi-tui";
import { EventRouter } from "./event-router.ts";
import type { EventRouterCallbacks } from "./event-router.ts";
import { parseCetasEvent } from "../events.ts";
import type { CetasEvent } from "../events.ts";
import { SubagentActivityStore } from "./subagent-activity.ts";
import type { ToolRow } from "../transcript/components.ts";

type StatusKind = Parameters<EventRouterCallbacks["setStatus"]>[0];

/** Build one parsed `subagent_event` from a raw child turn event. */
function childEvent(
  childSession: string,
  parentCall: string,
  inner: Record<string, unknown>,
): CetasEvent {
  const parsed = parseCetasEvent({
    type: "subagent_event",
    child_session: childSession,
    kind: "coder",
    parent_call: parentCall,
    ev: inner,
  });
  if (parsed === null) throw new Error("failed to parse subagent_event");
  return parsed;
}

function makeHarness(options: {
  subagentActivity?: SubagentActivityStore;
  canRefreshSubagentRow?: (row: ToolRow) => boolean;
} = {}) {
  const transcript = new Container();
  const redirects: Array<{ from: string; to: string }> = [];
  const statuses: Array<{ kind: StatusKind; message?: string }> = [];
  const callbacks: EventRouterCallbacks = {
    addTranscriptChild: (c) => transcript.addChild(c),
    setStatus: (kind, message) => statuses.push({ kind, message }),
    requestRender: () => {},
    cwd: "/tmp/fake",
    toolLabel: (name) => name,
    initialToolExpanded: () => false,
    onSessionRedirect: (from, to) => redirects.push({ from, to }),
    // Optional fields stay absent (not merely undefined) when omitted, so
    // the "plain harness" default path is exercised exactly as hosts see it.
    ...(options.subagentActivity !== undefined
      ? { subagentActivity: options.subagentActivity }
      : {}),
    ...(options.canRefreshSubagentRow !== undefined
      ? { canRefreshSubagentRow: options.canRefreshSubagentRow }
      : {}),
  };
  return {
    transcript,
    redirects,
    statuses,
    router: new EventRouter(callbacks),
    rendered: () => transcript.render(80).join("\n"),
    childCount: () => transcript.children.length,
  };
}

function ev(raw: object): CetasEvent {
  const parsed = parseCetasEvent(raw);
  if (parsed === null) throw new Error(`failed to parse: ${JSON.stringify(raw)}`);
  return parsed;
}

describe("EventRouter — session_redirect", () => {
  test("fires onSessionRedirect and still routes the notice", () => {
    const { router, redirects, rendered } = makeHarness();

    router.handleEvent(ev({ type: "session_redirect", from: "s_old", to: "s_new" }));

    expect(redirects).toEqual([{ from: "s_old", to: "s_new" }]);
    const out = rendered();
    expect(out).toContain("redirect: s_old → s_new");
  });

  test("onSessionRedirect is optional — absent callback still renders the notice", () => {
    const transcript = new Container();
    const router = new EventRouter({
      addTranscriptChild: (c) => transcript.addChild(c),
      setStatus: () => {},
      requestRender: () => {},
      cwd: "/tmp/fake",
      toolLabel: (name) => name,
      initialToolExpanded: () => false,
    });

    router.handleEvent(ev({ type: "session_redirect", from: "a", to: "b" }));

    const out = transcript.render(80).join("\n");
    expect(out).toContain("redirect: a → b");
  });
});

describe("EventRouter — late tool_call_completed", () => {
  test("a completion during a live turn reports phase feedback", () => {
    const { router, statuses } = makeHarness();

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(
      ev({ type: "tool_call_started", tool_call_id: "c1", tool_name: "read", args: {} }),
    );
    statuses.length = 0;
    router.handleEvent(
      ev({ type: "tool_call_completed", tool_call_id: "c1", result: "ok", is_error: false }),
    );

    expect(statuses).toEqual([{ kind: "working", message: "waiting for model" }]);
    router.handleEvent(ev({ type: "turn_completed" }));
  });

  test("a completion after endTurn does not resurrect the working status", () => {
    const { router, statuses } = makeHarness();

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(
      ev({ type: "tool_call_started", tool_call_id: "c1", tool_name: "read", args: {} }),
    );
    router.handleEvent(ev({ type: "turn_completed" }));
    statuses.length = 0;
    router.handleEvent(
      ev({ type: "tool_call_completed", tool_call_id: "c1", result: "late", is_error: false }),
    );

    expect(statuses).toEqual([]);
  });
});

// -- live subagent row refresh ----------------------------------------------

const AGENT_STARTED = {
  type: "tool_call_started",
  tool_call_id: "call_1",
  tool_name: "agent",
  args: {},
};

describe("EventRouter — refreshSubagentRow", () => {
  test("refreshes the pending agent row and reports true", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    const { router, rendered } = makeHarness({ subagentActivity: store });

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    expect(rendered()).toContain("step 1");

    // Child progress lands after the row mounted — stale until refreshed.
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    expect(rendered()).toContain("step 1");
    expect(router.refreshSubagentRow("call_1")).toBe(true);
    expect(rendered()).toContain("step 2");
  });

  test("absent visibility gate (plain unit harness) refreshes without a host", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    const { router } = makeHarness({ subagentActivity: store });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    expect(router.refreshSubagentRow("call_1")).toBe(true);
  });

  test("the host visibility gate can veto a refresh", () => {
    const store = new SubagentActivityStore();
    const { router, rendered } = makeHarness({
      subagentActivity: store,
      canRefreshSubagentRow: () => false,
    });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    expect(rendered()).not.toContain("step");

    // Child progress lands after mount; the gate vetoes the refresh.
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    expect(router.refreshSubagentRow("call_1")).toBe(false);
    expect(rendered()).not.toContain("step 1"); // still stale
  });

  test("a finished agent row refuses refresh", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    const { router, rendered } = makeHarness({ subagentActivity: store });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    router.handleEvent(
      ev({ type: "tool_call_completed", tool_call_id: "call_1", result: "wrapped up", is_error: false }),
    );
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    expect(router.refreshSubagentRow("call_1")).toBe(false);
    expect(rendered()).toContain("wrapped up");
    expect(rendered()).not.toContain("step 2");
  });

  test("unknown parent call reports false", () => {
    const { router } = makeHarness();
    expect(router.refreshSubagentRow("nope")).toBe(false);
  });

  test("after turn end pending rows lose refresh eligibility (late events no-op)", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    const { router, rendered } = makeHarness({ subagentActivity: store });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    router.handleEvent(ev({ type: "turn_completed" }));

    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    expect(router.refreshSubagentRow("call_1")).toBe(false);
    expect(rendered()).not.toContain("step 2");
  });
});

describe("EventRouter — refreshRunningSubagents (shell 1s tick)", () => {
  test("refreshes foreground rows once per parent call (dedupe)", () => {
    const store = new SubagentActivityStore();
    const { router, rendered } = makeHarness({ subagentActivity: store });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));

    // Two children spawned by the same `agent` call land after mount.
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    store.apply(childEvent("sub-2", "call_1", { type: "turn_started" }));
    expect(rendered()).not.toContain("step 1"); // stale until the tick

    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" })); // → step 2
    store.apply(childEvent("sub-2", "call_1", { type: "turn_started" })); // → step 2
    expect(router.refreshRunningSubagents()).toBe(1); // 2 records, 1 parent → one refresh
    expect(rendered()).toContain("step 2");
  });

  test("background children neither refresh nor create transcript rows", () => {
    const store = new SubagentActivityStore();
    store.apply(
      childEvent("bg-1", "background", {
        type: "custom",
        source: "posoco_ext_subagent",
        label: "background_spawned",
        data: { task_id: "task_1" },
      }),
    );
    store.apply(childEvent("bg-1", "background", { type: "turn_started" }));
    const { router, rendered, childCount } = makeHarness({
      subagentActivity: store,
    });
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev(AGENT_STARTED));
    const before = childCount();
    const beforeRender = rendered();

    expect(router.refreshRunningSubagents()).toBe(0);
    expect(childCount()).toBe(before); // no background row appeared
    expect(rendered()).toBe(beforeRender);
  });

  test("no store in callbacks refreshes nothing", () => {
    const { router } = makeHarness();
    expect(router.refreshRunningSubagents()).toBe(0);
  });

  test("streaming adoption re-keys the row so the renderer uses the final call id", () => {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_9", { type: "turn_started" }));
    const { router, rendered } = makeHarness({ subagentActivity: store });

    router.handleEvent(ev({ type: "turn_started" }));
    // Args stream in BEFORE the committed call — the row mounts keyed `#0`.
    router.handleEvent(ev({ type: "tool_args_delta", index: 0, delta: '{"preamble":"hi"}' }));
    router.handleEvent(
      ev({
        type: "tool_call_started",
        tool_call_id: "call_9",
        tool_name: "agent",
        args: { preamble: "hi" },
      }),
    );
    // The adopted row must resolve live data through the authoritative id.
    expect(rendered()).toContain("step 1");

    store.apply(childEvent("sub-1", "call_9", { type: "turn_started" }));
    expect(router.refreshSubagentRow("call_9")).toBe(true);
    expect(rendered()).toContain("step 2");
  });
});
