import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { visibleWidth } from "@earendil-works/pi-tui";

import type { SubagentActivity } from "../src/controllers/subagent-activity.ts";
import {
  projectSubagentHeader,
  renderSubagentHeader,
  SubagentHeader,
  subagentPhase,
  type SubagentHeaderProjection,
} from "./subagent-header.ts";

/** A running background record with only the fields the header reads. */
function backgroundRecord(overrides: Partial<SubagentActivity>): SubagentActivity {
  return {
    child_session: "child",
    kind: "coder",
    parent_call: "call_1",
    status: "running",
    started_at: 0,
    steps: 1,
    text_tail: "",
    history: [],
    version: 1,
    display_name: "apple",
    run_id: "call_1",
    seq: 0,
    terminal_received: false,
    terminal_notified: false,
    questions: [],
    background: true,
    ...overrides,
  };
}

function projectionOf(
  records: SubagentActivity[],
  options: { now?: number; height?: number; bottomReserve?: number; maxTasks?: number } = {},
): SubagentHeaderProjection {
  return projectSubagentHeader(records, { now: options.now ?? 53_000, ...options });
}

describe("projectSubagentHeader", () => {
  test("no current tool shows a phase word, never the stale last tool", () => {
    const thinking = backgroundRecord({ display_name: "apple" });
    const finishing = backgroundRecord({
      display_name: "banana",
      child_turn_state: "completed",
    });
    const stale = backgroundRecord({ display_name: "cherry", last_tool: "grep" });
    const projection = projectionOf([thinking, finishing, stale]);
    expect(projection.entries[0].tool).toBe("thinking");
    expect(projection.entries[1].tool).toBe("finishing");
    expect(projection.entries[2].tool).toBe("thinking");
    expect(projection.entries[2].detail).not.toContain("grep");
  });

  test("lists at most three tasks and folds the rest", () => {
    const records = ["a", "b", "c", "d", "e"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    const projection = projectionOf(records);
    expect(projection.total).toBe(5);
    expect(projection.entries.length).toBe(3);
    expect(projection.overflow).toBe(2);
    const lines = renderSubagentHeader(projection, 120);
    expect(lines.length).toBe(4);
    expect(lines[3]).toContain("+2 more");
    expect(lines[0]).toContain("subagent(a)");
    expect(lines[2]).toContain("subagent(c)");
  });

  test("stable order follows first appearance (seq), not mutation recency", () => {
    const records = [
      backgroundRecord({ display_name: "apple", seq: 0, started_at: 9_000 }),
      backgroundRecord({ display_name: "banana", seq: 1, started_at: 1_000 }),
    ];
    const projection = projectionOf(records);
    expect(projection.entries.map((entry) => entry.name)).toEqual(["apple", "banana"]);
  });

  test("skips records that are not background tasks", () => {
    const foreground = backgroundRecord({ background: false });
    const projection = projectionOf([foreground]);
    expect(projection.total).toBe(0);
  });

  test("terminal height and bottom reserve reduce the detail budget", () => {
    const records = ["a", "b", "c"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    // Extremely short viewport: single count line only.
    const tiny = projectionOf(records, { height: 8, bottomReserve: 6 });
    expect(tiny.detailBudget).toBe(0);
    expect(renderSubagentHeader(tiny, 120)).toEqual(["⚡ 3 subagents"]);
    // Tight viewport: one detail row.
    const tight = projectionOf(records, { height: 12, bottomReserve: 6 });
    expect(tight.detailBudget).toBe(1);
    // Comfortable viewport: default cap of three.
    const roomy = projectionOf(records, { height: 30, bottomReserve: 6 });
    expect(roomy.detailBudget).toBe(3);
  });

  test("a one-row budget with overflow shows the aggregate instead of hiding tasks", () => {
    const records = ["a", "b", "c"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    const lines = renderSubagentHeader(
      projectionOf(records, { maxTasks: 1 }),
      120,
    );
    expect(lines.length).toBe(1);
    expect(lines[0]).toContain("⚡ 3 subagents · +2 more");
  });
});

describe("renderSubagentHeader width handling", () => {
  const wide = backgroundRecord({
    display_name: "watermelon",
    kind: "翻译员🚀kind",
    current_tool: "very_long_tool_name_that_keeps_going",
  });

  test("every rendered line fits the terminal width (CJK + emoji safe)", () => {
    for (const width of [40, 80, 120]) {
      const lines = renderSubagentHeader(projectionOf([wide]), width);
      expect(lines.length).toBeGreaterThan(0);
      for (const line of lines) {
        expect(visibleWidth(line)).toBeLessThanOrEqual(width);
      }
    }
  });

  test("extremely narrow terminals degrade to a single total line", () => {
    const records = ["a", "b"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    const lines = renderSubagentHeader(projectionOf(records), 20);
    expect(lines.length).toBe(1);
    expect(visibleWidth(lines[0])).toBeLessThanOrEqual(20);
    expect(lines[0]).toContain("2 subagents");
    expect(lines[0]).not.toContain("subagent(a");
  });

  test("zero or negative width renders nothing", () => {
    expect(renderSubagentHeader(projectionOf([wide]), 0)).toEqual([]);
  });
});

describe("SubagentHeader component", () => {
  const nativeInterval = globalThis.setInterval;
  afterEach(() => {
    globalThis.setInterval = nativeInterval;
  });

  test("renders from its source and never starts a timer", () => {
    const intervalSpy = spyOn(globalThis, "setInterval").mockImplementation(
      nativeInterval as typeof setInterval,
    );
    let records: SubagentActivity[] = [
      backgroundRecord({ display_name: "apple", current_tool: "bash" }),
    ];
    const component = new SubagentHeader(() => ({ records, now: 53_000 }));
    const lines = component.render(80);
    expect(lines.length).toBe(1);
    expect(lines[0]).toContain("subagent(apple)");

    records = [];
    expect(component.render(80)).toEqual([]);
    expect(intervalSpy).not.toHaveBeenCalled();
  });
});

describe("subagentPhase", () => {
  test("a parked question outranks the current tool", () => {
    const record = backgroundRecord({
      current_tool: "ask_question_child",
      questions: [{ id: "question-1", text: "q", type: "select", asked_at: 0 }],
    });
    expect(subagentPhase(record)).toBe("? waiting your answer");
  });
});
