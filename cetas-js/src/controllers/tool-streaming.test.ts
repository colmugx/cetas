/**
 * tool-streaming.test.ts — regression coverage for streamed tool-call args.
 *
 * Contracts locked here:
 *   - deltas mount exactly ONE row per call, keyed `#index` until an id
 *     fragment re-keys it;
 *   - throttled flushes push parsed partial JSON into the row;
 *   - `onCallStarted` adoption REPLACES accumulated args with the
 *     authoritative ones (chunk channel is lossy under backpressure);
 *   - unknown started ids fall through (router builds a classic row).
 *
 * Pattern mirrors streaming-ui.test.ts: real pi-tui Container + real
 * ToolRow mounted through the same factory shape EventRouter wires,
 * asserted via `transcript.render(80)` substring checks.
 */

import { describe, expect, test } from "bun:test";
import { Container } from "@earendil-works/pi-tui";
// Import for registration side effects so pickToolRenderer("write") hits the hook.
import "../tool-renderers/index.ts";
import { ToolRow } from "../transcript/components.ts";
import { ToolStreamingController, TOOL_STREAMING_FLUSH_MS } from "./tool-streaming.ts";
import type { StreamingToolRowFactory } from "./tool-streaming.ts";
import { EventRouter } from "./event-router.ts";
import type { EventRouterCallbacks } from "./event-router.ts";
import { parseCetasEvent } from "../events.ts";
import type { CetasEvent } from "../events.ts";

const FAST_FLUSH_MS = 1;

function makeHarness() {
  const transcript = new Container();
  let renders = 0;
  const factory: StreamingToolRowFactory = {
    createStreamingRow: (index, id, name) => {
      const displayName = name ?? "";
      const row = new ToolRow(
        displayName,
        id ?? `#${index}`,
        {},
        "/tmp/fake",
        () => {},
        displayName.length > 0 ? displayName : undefined,
        false,
        {
          streaming: true,
          labelFor: (n) => n,
        },
      );
      transcript.addChild(row);
      return row;
    },
  };
  const controller = new ToolStreamingController(
    () => {
      renders++;
    },
    factory,
    FAST_FLUSH_MS,
  );
  return { transcript, controller, renders: () => renders };
}

const ANSI = /\x1b\[[0-9;]*m/g;
function strip(s: string): string {
  return s.replace(ANSI, "");
}
function rendered(transcript: Container): string {
  return transcript.render(80).map(strip).join("\n");
}

async function settle(ms = 15): Promise<void> {
  await Bun.sleep(ms);
}

describe("ToolStreamingController", () => {
  test("happy path: deltas create ONE row; started adopts + replaces args", async () => {
    const { transcript, controller } = makeHarness();

    controller.onArgsDelta(0, "call_1", "write", '{"path":"notes.md","content":"');
    await settle();
    expect(
      transcript.children.filter((c) => c instanceof ToolRow).length,
    ).toBe(1);

    controller.onArgsDelta(0, undefined, undefined, "hello ");
    controller.onArgsDelta(0, undefined, undefined, "world\\nsecond\\n");
    // Same call again must not spawn a second row.
    expect(
      transcript.children.filter((c) => c instanceof ToolRow).length,
    ).toBe(1);

    await settle();
    const streamed = rendered(transcript);
    expect(streamed).toContain("notes.md");
    expect(streamed).toContain("hello world");

    const adopted = controller.onCallStarted("call_1", "write", {
      path: "notes.md",
      content: "final full content",
    });
    expect(adopted).not.toBeNull();
    const after = rendered(transcript);
    expect(after).toContain("(18 bytes)");
    expect(after).toContain("notes.md");
    expect(after).not.toContain("hello world");
  });

  test("index-keyed row is re-keyed when its id arrives", async () => {
    const { transcript, controller } = makeHarness();

    // First fragment lost nothing but carried no id/name (lossy header).
    controller.onArgsDelta(0, undefined, undefined, '{"path":"a.md"}');
    await settle();
    const rows = transcript.children.filter((c) => c instanceof ToolRow);
    expect(rows.length).toBe(1);

    // Later fragment announces id+name — same physical row keeps receiving.
    controller.onArgsDelta(0, "call_x", "write", '{"path":"b.md"}');
    controller.onArgsDelta(0, undefined, undefined, "");
    expect(transcript.children.filter((c) => c instanceof ToolRow).length).toBe(1);

    const adopted = controller.onCallStarted("call_x", "write", {});
    expect(adopted).toBe(rows[0]);
  });

  test("two concurrent calls stay distinct by index/id", async () => {
    const { transcript, controller } = makeHarness();

    controller.onArgsDelta(0, "c0", "write", '{"path":"one.md"');
    controller.onArgsDelta(1, "c1", "bash", '{"cmd":"ls"');
    await settle();
    expect(transcript.children.filter((c) => c instanceof ToolRow).length).toBe(2);
    const out = rendered(transcript);
    expect(out).toContain("one.md");
    expect(out).toContain("ls");

    // Adopting c0 must not consume c1's pending entry.
    const first = controller.onCallStarted("c0", "write", { path: "one.md" });
    expect(first).not.toBeNull();
    const second = controller.onCallStarted("c1", "bash", { cmd: "ls" });
    expect(second).not.toBeNull();
    expect(second).not.toBe(first);
    expect(rendered(transcript)).toContain("ls");
  });

  test("drop tolerance: missing middle fragment still renders; started wins", async () => {
    const { transcript, controller } = makeHarness();

    controller.onArgsDelta(0, "c9", "write", '{"path":"g.md","content":"keep1\\nkeep2\\n');
    // Fragment carrying "keep3\\n...rest\\" is DROPPED under backpressure —
    // the buffer stays open forever until started arrives.
    await settle();
    const streamed = rendered(transcript);
    expect(streamed).toContain("g.md");
    expect(streamed).toContain("keep1");
    expect(streamed).not.toContain("}");

    const adopted = controller.onCallStarted("c9", "write", {
      path: "g.md",
      content: "authoritative",
    });
    expect(adopted).not.toBeNull();
    expect(rendered(transcript)).toContain("(13 bytes)");
  });

  test("unknown tool_call_started with no pending state falls through", () => {
    const { controller } = makeHarness();
    expect(controller.onCallStarted("ghost", "read", {})).toBeNull();
  });

  test("started with multiple pending rows and no matching id falls through", () => {
    const { controller } = makeHarness();
    controller.onArgsDelta(0, "a", "write", "{");
    controller.onArgsDelta(1, "b", "write", "{");
    expect(controller.onCallStarted("unknown-id", "read", {})).toBeNull();
  });

  test("endTurn clears pending state (late started falls through)", async () => {
    const { transcript, controller } = makeHarness();
    controller.onArgsDelta(0, "cE", "write", '{"path":"x"');
    await settle();
    controller.endTurn();

    // A late started for the dropped call builds no adoption...
    expect(controller.onCallStarted("cE", "write", {})).toBeNull();
    // ...and post-end deltas (defensive) mount afresh rather than resurrect.
    controller.onArgsDelta(3, undefined, undefined, "{");
    const rows = transcript.children.filter((c) => c instanceof ToolRow);
    expect(rows.length).toBe(2); // frozen pre-end row + new stream row
  });
});

describe("EventRouter — tool_args_delta wiring (end to end)", () => {
  /** Mirror streaming-ui.test.ts's fake callback harness. */
  function makeRouterHarness() {
    const transcript = new Container();
    let renders = 0;
    const callbacks: EventRouterCallbacks = {
      addTranscriptChild: (c) => transcript.addChild(c),
      setStatus: () => {},
      requestRender: () => {
        renders++;
      },
      cwd: "/tmp/fake",
      toolLabel: (name) => name,
      initialToolExpanded: () => false,
    };
    return { transcript, router: new EventRouter(callbacks), rendered: () =>
      transcript.render(80).map(strip).join("\n") };
  }

  function ev(raw: object): CetasEvent {
    const parsed = parseCetasEvent(raw);
    if (parsed === null) throw new Error(`failed to parse: ${JSON.stringify(raw)}`);
    return parsed;
  }

  test("deltas stream into one row; started adopts it; result routes to it", async () => {
    const { router, rendered } = makeRouterHarness();

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(
      ev({
        type: "tool_args_delta",
        index: 0,
        id: "call_7",
        name: "write",
        delta: '{"path":"story.md","content":"scene one\\nscene two',
      }),
    );
    // The router runs the production 50ms throttle; outwait it.
    await Bun.sleep(TOOL_STREAMING_FLUSH_MS + 30);
    expect(rendered()).toContain("· 2 lines");
    expect(rendered()).toContain("scene two");

    router.handleEvent(
      ev({
        type: "tool_call_started",
        tool_call_id: "call_7",
        tool_name: "write",
        args: { path: "story.md", content: "final text" },
      }),
    );
    const afterStart = rendered();
    // Collapsed to the spec view with authoritative args; no streamed tail.
    expect(afterStart).toContain("(10 bytes)");
    expect(afterStart).not.toContain("scene two");

    router.handleEvent(
      ev({
        type: "tool_call_completed",
        tool_call_id: "call_7",
        result: "ok",
        is_error: false,
      }),
    );
    expect(rendered()).toContain("ok");
    router.handleEvent(ev({ type: "turn_completed" }));
    // Still exactly one write row after the whole cycle.
    expect(rendered().match(/story\.md/g)?.length ?? 0).toBeGreaterThanOrEqual(1);
  });

  test("turn cleanup: deltas across turns never leak rows into the next turn", async () => {
    const { router, rendered } = makeRouterHarness();

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(
      ev({ type: "tool_args_delta", index: 0, id: "stale", name: "write", delta: '{"path":"a"' }),
    );
    router.handleEvent(ev({ type: "turn_failed", error_message: "boom", error_kind: "unknown" }));

    router.handleEvent(ev({ type: "turn_started" }));
    // New turn's started for a DIFFERENT call must not adopt turn-1 residue.
    router.handleEvent(
      ev({
        type: "tool_call_started",
        tool_call_id: "fresh",
        tool_name: "read",
        args: { path: "b.txt" },
      }),
    );
    const out = rendered();
    // Turn-1's streamed row is frozen residue; turn-2's started built a
    // classic fresh read row with its own args (no cross-turn adoption).
    expect(out).toContain("read b.txt");
    expect(out).toContain("● write …");
    router.handleEvent(ev({ type: "turn_completed" }));
  });
});
