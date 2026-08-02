/**
 * streaming-ui.test.ts — regression coverage for the step-block streaming model.
 *
 * These tests lock in the two bugs the refactor fixes:
 *   - Bug #1: reasoning after a tool call (text→reasoning transition) must
 *     open a NEW step/block, not overwrite the previous step's ThinkingComponent.
 *   - Bug #2-b: the post-hoc `message_end` replay must NOT re-render reasoning
 *     or text that streaming already showed.
 *
 * Pattern (mirrors ui/extension-ui.test.ts): real pi-tui `Container` driven by
 * a fake `StreamingComponentFactory` / `EventRouterCallbacks`, asserted via
 * `container.render(80).join("\n")` substring checks and `children` length.
 */

import { describe, expect, test } from "bun:test";
import { Container } from "@earendil-works/pi-tui";
import { EventRouter } from "./event-router.ts";
import type { EventRouterCallbacks } from "./event-router.ts";
import { StreamingUIController } from "./streaming-ui.ts";
import type { StreamingComponentFactory } from "./streaming-ui.ts";
import { AssistantMessage } from "../transcript/components.ts";
import { ThinkingComponent } from "../transcript/thinking.ts";
import { parseCetasEvent } from "../events.ts";
import type { CetasEvent } from "../events.ts";

// Use a tiny flush interval so timer-based flushes resolve within a tick in
// tests. We mostly drive synchronous flushes via end()/closeStep().
const FAST_FLUSH_MS = 1;

/** Build a real transcript + fake callbacks for EventRouter integration. */
function makeTranscriptHarness() {
  const transcript = new Container();
  const statusCalls: Array<{ kind: string; message?: string }> = [];
  let renderCalls = 0;
  const callbacks: EventRouterCallbacks = {
    addTranscriptChild: (c) => transcript.addChild(c),
    setStatus: (kind, message) => statusCalls.push({ kind, message }),
    requestRender: () => {
      renderCalls++;
    },
    cwd: "/tmp/fake",
  };
  return { transcript, statusCalls, renderCalls, callbacks };
}

/** Build a StreamingUIController wired to a real transcript Container. */
function makeController(transcript: Container) {
  const factory: StreamingComponentFactory = {
    createThinking: () => {
      const comp = new ThinkingComponent("", "live");
      transcript.addChild(comp);
      return comp;
    },
    createText: () => {
      const comp = new AssistantMessage("");
      transcript.addChild(comp);
      return comp;
    },
    addTranscriptChild: (c) => transcript.addChild(c),
  };
  let renders = 0;
  const controller = new StreamingUIController(
    () => {
      renders++;
    },
    factory,
    FAST_FLUSH_MS,
  );
  return { controller, renders };
}

/** Count direct children of a given component type in a transcript. */
function countChildren(transcript: Container, ctor: Function): number {
  return transcript.children.filter((c) => c instanceof ctor).length;
}

/** Helper: build a CetasEvent from a raw object, asserting it parsed. */
function ev(raw: object): CetasEvent {
  const parsed = parseCetasEvent(raw);
  if (parsed === null) throw new Error(`failed to parse event: ${JSON.stringify(raw)}`);
  return parsed;
}

describe("StreamingUIController — step-block model", () => {
  test("single step: reasoning then text produces one thinking + one text block", () => {
    const { transcript } = makeTranscriptHarness();
    const { controller } = makeController(transcript);

    controller.appendReasoning("r1");
    controller.appendReasoning("r2");
    controller.appendText("t1");
    controller.appendText("t2");
    controller.closeStep();

    expect(countChildren(transcript, ThinkingComponent)).toBe(1);
    expect(countChildren(transcript, AssistantMessage)).toBe(1);

    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("r1r2");
    expect(rendered).toContain("t1t2");
  });

  test("Bug #1 regression: text→reasoning opens a NEW step (no overwrite)", () => {
    const { transcript } = makeTranscriptHarness();
    const { controller } = makeController(transcript);

    // Step 1: reasoning A + text A
    controller.appendReasoning("A-thought");
    controller.appendText("A-answer");
    controller.closeStep();

    // Step 2: reasoning B + text B (text→reasoning transition = new step)
    controller.appendReasoning("B-thought");
    controller.appendText("B-answer");
    controller.closeStep();

    expect(countChildren(transcript, ThinkingComponent)).toBe(2);
    expect(countChildren(transcript, AssistantMessage)).toBe(2);

    const rendered = transcript.render(80).join("\n");
    // Both steps' content survives, distinct.
    expect(rendered).toContain("A-thought");
    expect(rendered).toContain("A-answer");
    expect(rendered).toContain("B-thought");
    expect(rendered).toContain("B-answer");
  });

  test("Bug #1 without explicit closeStep: controller detects boundary internally", () => {
    // Mirrors reality: no message_end between steps; the controller must infer
    // the step boundary from the text→reasoning transition alone.
    const { transcript } = makeTranscriptHarness();
    const { controller } = makeController(transcript);

    controller.appendReasoning("step1-reasoning");
    controller.appendText("step1-text");
    // No closeStep() — next reasoning triggers boundary detection.
    controller.appendReasoning("step2-reasoning");
    controller.appendText("step2-text");
    controller.closeStep();

    expect(countChildren(transcript, ThinkingComponent)).toBe(2);
    expect(countChildren(transcript, AssistantMessage)).toBe(2);

    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("step1-text");
    expect(rendered).toContain("step2-text");
  });

  test("closeStep freezes thinking: subsequent reasoning does not mutate old block", () => {
    const { transcript } = makeTranscriptHarness();
    const { controller } = makeController(transcript);

    controller.appendReasoning("first");
    controller.closeStep();

    controller.appendReasoning("second");
    controller.closeStep();

    expect(countChildren(transcript, ThinkingComponent)).toBe(2);
    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("first");
    expect(rendered).toContain("second");
  });

  test("text-only step (no reasoning) works", () => {
    const { transcript } = makeTranscriptHarness();
    const { controller } = makeController(transcript);

    controller.appendText("just text");
    controller.closeStep();

    expect(countChildren(transcript, ThinkingComponent)).toBe(0);
    expect(countChildren(transcript, AssistantMessage)).toBe(1);
    expect(transcript.render(80).join("\n")).toContain("just text");
  });
});

describe("EventRouter — integration with step model + message_end dedup", () => {
  test("Bug #2 regression: multi-step turn with post-hoc message_end replay, no duplication", () => {
    const { transcript, callbacks } = makeTranscriptHarness();
    const router = new EventRouter(callbacks);

    // Full multi-step turn: stream two steps live, then the bridge replays
    // message_end for BOTH assistant messages after the pump finishes.
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "reasoning", raw: "think-A" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "text", raw: "answer-A" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "reasoning", raw: "think-B" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "text", raw: "answer-B" }));
    // Post-hoc replay: message_end for step A's message.
    router.handleEvent(
      ev({
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "answer-A" }],
          reasoning: "think-A",
        },
      }),
    );
    // Tool call between steps (matches real event order).
    router.handleEvent(
      ev({
        type: "tool_call_started",
        tool_call_id: "tc1",
        tool_name: "read",
        args: {},
      }),
    );
    router.handleEvent(
      ev({
        type: "tool_call_completed",
        tool_call_id: "tc1",
        result: "ok",
        is_error: false,
      }),
    );
    // Post-hoc replay: message_end for step B's message.
    router.handleEvent(
      ev({
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "answer-B" }],
          reasoning: "think-B",
        },
      }),
    );
    router.handleEvent(ev({ type: "turn_completed" }));

    // Each answer appears exactly once — the replay did not re-render.
    expect(countChildren(transcript, AssistantMessage)).toBe(2);
    expect(countChildren(transcript, ThinkingComponent)).toBe(2);
    const rendered = transcript.render(80).join("\n");
    // "answer-A" should appear once in the text blocks (count occurrences).
    expect(rendered.match(/answer-A/g)?.length ?? 0).toBe(1);
    expect(rendered.match(/answer-B/g)?.length ?? 0).toBe(1);
    // No Debug-form reasoning leak ("Reasoning(N chars)").
    expect(rendered).not.toMatch(/Reasoning\(\d+ chars\)/);
  });

  test("Path B still works: non-streaming provider builds blocks from message_end", () => {
    const { transcript, callbacks } = makeTranscriptHarness();
    const router = new EventRouter(callbacks);

    router.handleEvent(ev({ type: "turn_started" }));
    // No stream_chunks at all — message_end is the only signal.
    router.handleEvent(
      ev({
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "non-streamed answer" }],
          reasoning: "non-streamed reasoning",
        },
      }),
    );
    router.handleEvent(ev({ type: "turn_completed" }));

    expect(countChildren(transcript, AssistantMessage)).toBe(1);
    expect(countChildren(transcript, ThinkingComponent)).toBe(1);
    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("non-streamed answer");
    expect(rendered).toContain("non-streamed reasoning");
  });

  test("cross-turn isolation: two turns do not overwrite each other", () => {
    const { transcript, callbacks } = makeTranscriptHarness();
    const router = new EventRouter(callbacks);

    // Turn 1
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "text", raw: "turn1-answer" }));
    router.handleEvent(
      ev({
        type: "message_end",
        message: { role: "assistant", content: [{ type: "text", text: "turn1-answer" }] },
      }),
    );
    router.handleEvent(ev({ type: "turn_completed" }));

    // Turn 2
    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(ev({ type: "stream_chunk", kind: "text", raw: "turn2-answer" }));
    router.handleEvent(
      ev({
        type: "message_end",
        message: { role: "assistant", content: [{ type: "text", text: "turn2-answer" }] },
      }),
    );
    router.handleEvent(ev({ type: "turn_completed" }));

    expect(countChildren(transcript, AssistantMessage)).toBe(2);
    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("turn1-answer");
    expect(rendered).toContain("turn2-answer");
  });

  test("turn_failed surfaces an error notice and ends the turn cleanly", () => {
    const { transcript, callbacks } = makeTranscriptHarness();
    const router = new EventRouter(callbacks);

    router.handleEvent(ev({ type: "turn_started" }));
    router.handleEvent(
      ev({
        type: "turn_failed",
        error_message: "boom",
        error_kind: "unknown",
      }),
    );

    const rendered = transcript.render(80).join("\n");
    expect(rendered).toContain("boom");
  });
});
