import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { visibleWidth } from "@earendil-works/pi-tui";

import type { SubagentActivity } from "../src/controllers/subagent-activity.ts";
import {
  formatSubagentElapsed,
  projectSubagentHeader,
  renderSubagentHeader,
  subagentHeaderEquals,
  SubagentHeader,
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

describe("formatSubagentElapsed", () => {
  test("seconds, minutes, hours", () => {
    expect(formatSubagentElapsed(0, 0)).toBe("0s");
    expect(formatSubagentElapsed(0, 53_000)).toBe("53s");
    expect(formatSubagentElapsed(0, 59_999)).toBe("59s");
    expect(formatSubagentElapsed(0, 60_000)).toBe("1m");
    expect(formatSubagentElapsed(0, 3_599_000)).toBe("59m");
    expect(formatSubagentElapsed(0, 3_600_000)).toBe("1h");
    expect(formatSubagentElapsed(0, 7_321_000)).toBe("2h");
  });
});

describe("projectSubagentHeader", () => {
  test("no records project to an empty header", () => {
    const projection = projectionOf([]);
    expect(projection.total).toBe(0);
    expect(projection.entries).toEqual([]);
    expect(projection.overflow).toBe(0);
    expect(renderSubagentHeader(projection, 80)).toEqual([]);
  });

  test("single task matches the approved line format", () => {
    const record = backgroundRecord({
      display_name: "apple",
      kind: "coder",
      started_at: 0,
      current_tool: "bash",
    });
    const projection = projectionOf([record], { now: 53_000 });
    expect(projection.total).toBe(1);
    expect(projection.entries.length).toBe(1);
    expect(projection.entries[0].detail).toBe("agent(apple) · coder 53s · bash");
    const lines = renderSubagentHeader(projection, 80);
    expect(lines.length).toBe(1);
    expect(lines[0]).toContain("⚡ 1 agent(apple) · coder 53s · bash");
  });

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
    expect(lines[0]).toContain("agent(a)");
    expect(lines[2]).toContain("agent(c)");
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
    expect(renderSubagentHeader(tiny, 120)).toEqual(["⚡ 3 agents"]);
    // Tight viewport: one detail row.
    const tight = projectionOf(records, { height: 12, bottomReserve: 6 });
    expect(tight.detailBudget).toBe(1);
    // Comfortable viewport: default cap of three.
    const roomy = projectionOf(records, { height: 30, bottomReserve: 6 });
    expect(roomy.detailBudget).toBe(3);
  });

  test("maxTasks override tightens the cap", () => {
    const records = ["a", "b"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    const projection = projectionOf(records, { maxTasks: 1 });
    expect(projection.entries.length).toBe(1);
    expect(projection.overflow).toBe(1);
  });

  test("every task line reads `⚡ 1 agent(name)`; the total only in aggregates", () => {
    const records = ["a", "b", "c", "d"].map((name, index) =>
      backgroundRecord({ display_name: name, seq: index }),
    );
    const lines = renderSubagentHeader(projectionOf(records), 120);
    expect(lines.length).toBe(4);
    for (const line of lines.slice(0, 3)) {
      expect(line).toContain("⚡ 1 agent(");
      expect(line).not.toContain("agents");
    }
    // The overflow aggregate is where the total shows up.
    expect(lines[3]).toContain("⚡ 4 agents · +1 more");
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
    expect(lines[0]).toContain("⚡ 3 agents · +2 more");
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
    expect(lines[0]).toContain("2 agents");
    expect(lines[0]).not.toContain("agent(a");
  });

  test("zero or negative width renders nothing", () => {
    expect(renderSubagentHeader(projectionOf([wide]), 0)).toEqual([]);
  });
});

describe("subagentHeaderEquals", () => {
  const base = () =>
    projectionOf([
      backgroundRecord({ display_name: "apple", current_tool: "bash" }),
    ]);

  test("identical projections are equal", () => {
    expect(subagentHeaderEquals(base(), base())).toBe(true);
  });

  test("tool, elapsed, count and budget changes are differences", () => {
    const toolChanged = projectionOf([
      backgroundRecord({ display_name: "apple", current_tool: "read" }),
    ]);
    expect(subagentHeaderEquals(base(), toolChanged)).toBe(false);

    const elapsedChanged = projectionOf(
      [backgroundRecord({ display_name: "apple", current_tool: "bash" })],
      { now: 54_000 },
    );
    expect(subagentHeaderEquals(base(), elapsedChanged)).toBe(false);

    const more = projectionOf([
      backgroundRecord({ display_name: "apple", current_tool: "bash" }),
      backgroundRecord({ display_name: "banana", seq: 1 }),
    ]);
    expect(subagentHeaderEquals(base(), more)).toBe(false);

    const budgetChanged = projectionOf(
      [backgroundRecord({ display_name: "apple", current_tool: "bash" })],
      { height: 8, bottomReserve: 6 },
    );
    expect(subagentHeaderEquals(base(), budgetChanged)).toBe(false);
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
    expect(lines[0]).toContain("agent(apple)");

    records = [];
    expect(component.render(80)).toEqual([]);
    expect(intervalSpy).not.toHaveBeenCalled();
  });

  test("absent source renders nothing", () => {
    const component = new SubagentHeader(() => undefined);
    expect(component.render(80)).toEqual([]);
  });

  test("invalidate and handleInput are safe no-ops", () => {
    const component = new SubagentHeader(() => undefined);
    component.invalidate();
    component.handleInput("x");
  });
});
