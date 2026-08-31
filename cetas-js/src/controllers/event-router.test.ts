/**
 * event-router.test.ts — session_redirect follow-through and the late
 * tool_call_completed status guard.
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

type StatusKind = Parameters<EventRouterCallbacks["setStatus"]>[0];

function makeHarness() {
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
  };
  return {
    transcript,
    redirects,
    statuses,
    router: new EventRouter(callbacks),
    rendered: () => transcript.render(80).join("\n"),
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
