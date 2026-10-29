import { describe, expect, test } from "bun:test";
import { BoardActivityStore } from "./board-activity.ts";

function state(runs: unknown[]): unknown {
  return { questions: [], runs };
}

describe("BoardActivityStore", () => {
  test("projects only running ticket runs and keeps stable order", () => {
    const store = new BoardActivityStore();
    expect(store.update(state([
      {
        task_id: "task-1",
        phase: "shape",
        status: "running",
        steps: 2,
        current_tool: "read",
        preview: "Looking at the ticket",
        reasoning: "Need context",
        activities: [
          { at_ms: 1000, kind: "step", text: "Step 1 started" },
          { at_ms: 1200, kind: "tool", text: "Tool · read · src/ticket.mbt" },
        ],
      },
      { task_id: "task-2", phase: "work", status: "review", steps: 4 },
    ]))).toBe(true);
    const running = store.running();
    expect(running).toHaveLength(1);
    expect(running[0]!.task_id).toBe("task-1");
    expect(running[0]!.steps).toBe(2);
    expect(running[0]!.current_tool).toBe("read");
    expect(running[0]!.last_activity).toContain("src/ticket.mbt");
    expect(running[0]!.started_at).toBe(1000);
  });

  test("returns false for an unchanged projection and removes completed runs", () => {
    const store = new BoardActivityStore();
    const running = state([
      { task_id: "task-1", phase: "shape", status: "running", steps: 1 },
    ]);
    expect(store.update(running)).toBe(true);
    expect(store.update(running)).toBe(false);
    expect(store.update(state([
      { task_id: "task-1", phase: "shape", status: "shaped", steps: 2 },
    ]))).toBe(true);
    expect(store.running()).toHaveLength(0);
  });

  test("a restarted run gets a fresh order after disappearing", () => {
    const store = new BoardActivityStore();
    store.update(state([
      { task_id: "a", phase: "work", status: "running", steps: 1 },
      { task_id: "b", phase: "work", status: "running", steps: 1 },
    ]));
    store.update(state([]));
    store.update(state([
      { task_id: "b", phase: "work", status: "running", steps: 1 },
      { task_id: "a", phase: "work", status: "running", steps: 1 },
    ]));
    expect(store.running().map((item) => item.task_id)).toEqual(["b", "a"]);
  });
});

describe("BoardActivityStore presence", () => {
  test("projects the authoritative Board presence", () => {
    const store = new BoardActivityStore();
    store.update({
      presence: { state: "blocked", running: 1, waiting_input: 2, attention: 0, message: "Waiting" },
      questions: [],
      runs: [],
    });
    expect(store.presence()).toEqual({
      state: "blocked",
      running: 1,
      waiting_input: 2,
      attention: 0,
      message: "Waiting",
    });
    store.clear();
    expect(store.presence().state).toBe("idle");
  });
});
