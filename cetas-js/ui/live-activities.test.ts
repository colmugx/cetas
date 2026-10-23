import { describe, expect, test } from "bun:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import type { SubagentActivity } from "../src/controllers/subagent-activity.ts";
import type { BoardActivity } from "../src/controllers/board-activity.ts";
import { projectLiveActivities, questionPreview, renderLiveActivities, type LiveActivitiesSource } from "./live-activities.ts";

function agent(extra: Partial<SubagentActivity> = {}): SubagentActivity {
  return {
    child_session: "c1", kind: "coder", parent_call: "call-1", status: "running",
    started_at: 0, steps: 1, text_tail: "", history: [], version: 1,
    display_name: "banana", run_id: "call-1", seq: 0,
    terminal_received: false, terminal_notified: false, background: true, task_id: "t1", ...extra,
  };
}
const base = (records: SubagentActivity[]): LiveActivitiesSource => ({
  records, wakeups: [], resultsWaiting: 0, activeDecisions: 0, now: 53000,
});
describe("Live Activities replacement header", () => {
  test("live question supersedes a running agent row and answer removes it", () => {
    const record = agent({question: {id:"question-1",type:"input",text:"Which API should we expose?",asked_at:1000}});
    const question = projectLiveActivities(base([record]));
    const shown = renderLiveActivities(question, 120).join("\n");
    expect(shown).toContain('agent(banana) asks main');
    expect(shown).toContain('Which API should we expose?');
    expect(shown).not.toContain("coder 53s");
    record.question = undefined;
    const answered = renderLiveActivities(projectLiveActivities(base([record])),120).join("\n");
    expect(answered).toContain("coder 53s");
    expect(answered).not.toContain("answered");
    expect(answered).not.toContain("asks main");
  });
  test("foreground questions appear without duplicate foreground tool rows", () => {
    const record = agent({background:false,task_id:undefined,question: {id:"q2",type:"confirm",text:"Need approval?",asked_at:0}});
    expect(renderLiveActivities(projectLiveActivities(base([record])), 100).join("")).toContain("asks main");
    record.question = undefined;
    expect(renderLiveActivities(projectLiveActivities(base([record])), 100)).toEqual([]);
  });
  test("wakeup, receipts, decisions share one bounded priority window", () => {
    const src: LiveActivitiesSource = {
      ...base([agent({question:{id:"q",text:"question",type:"input",asked_at:0}})]),
      resultsWaiting: 2, activeDecisions: 3,
      wakeups:[{ticket_id:"w",session:"owner",tag:"build-watch",extension_id:"ext",state:"executing",enqueued_at:0}],
    };
    const projection=projectLiveActivities(src);
    expect(projection.total).toBe(4);
    expect(renderLiveActivities(projection,120).join("\n")).toContain("wakeup build-watch");
    expect(renderLiveActivities(projection,120).join("\n")).toContain("coordination");
  });
  test("more than four rows fold instead of scrolling transcript", () => {
    const records=Array.from({length:7},(_,i)=>agent({child_session:`child-${i}`,display_name:`agent-${i}`,seq:i}));
    const projection=projectLiveActivities(base(records));
    expect(projection.hidden).toBe(4);
    expect(renderLiveActivities(projection,120)).toHaveLength(4);
    expect(renderLiveActivities(projection,120).at(-1)).toContain("+ 4 more");
  });
  test("CJK, ANSI-like raw questions, narrow/short terminals remain in bounds", () => {
    const record=agent({question:{id:"q",type:"input",text:"汉字".repeat(100) + "\x1b[31m secret",asked_at:0}});
    expect(questionPreview(record.question!.text)).not.toContain("\x1b");
    for(const width of [0,1,2,12,23,24,60,120]) {
      const lines=renderLiveActivities(projectLiveActivities({...base([record]),height:8,bottomReserve:5}),width);
      expect(lines.every(line=>visibleWidth(line)<=width)).toBe(true);
    }
  });
  test("a running Board ticket shows its live phase in the Activities header", () => {
    const board: BoardActivity = {
      key: "task-123456789:shape",
      task_id: "task-123456789",
      phase: "shape",
      status: "running",
      steps: 3,
      current_tool: "read",
      preview: "Looking at the ticket flow",
      reasoning: "Need more context",
      last_activity: "Tool · read · src/ticket.mbt",
      started_at: 0,
      seq: 0,
    };
    const lines = renderLiveActivities(projectLiveActivities({
      ...base([]), boardActivities: [board],
    }), 120);
    expect(lines.join("\n")).toContain("board(shaping");
    expect(lines.join("\n")).toContain("3 steps");
    expect(lines.join("\n")).toContain("read");
  });

  test("a parked human question outranks agent rows and uses its short id", () => {    const src: LiveActivitiesSource = {
      ...base([agent({ question: { id: "q-child", type: "input", text: "child q", asked_at: 0 } })]),
      userQuestions: [
        {
          id: "question-7",
          short_id: "@q7",
          text: "Upgrade node to 22?",
          kind: "confirm",
          deadline_at: 0,
        },
      ],
    };
    const lines = renderLiveActivities(projectLiveActivities(src), 120);
    expect(lines[0]).toContain("@q7 asks you");
    expect(lines[0]).toContain("Upgrade node to 22?");
    expect(lines[0]).toContain("/answer @q7");
    expect(lines.join("\n")).toContain("agent(banana) asks main");
  });
  test("answered questions leave no header row at all", () => {
    const src: LiveActivitiesSource = { ...base([]), userQuestions: [] };
    expect(renderLiveActivities(projectLiveActivities(src), 120)).toEqual([]);
  });
  test("a long human question is truncated, never wrapped past the width", () => {
    const src: LiveActivitiesSource = {
      ...base([]),
      userQuestions: [
        { id: "question-1", short_id: "@q1", text: "x".repeat(400), kind: "input", deadline_at: 0 },
      ],
    };
    for (const width of [1, 12, 24, 80]) {
      const lines = renderLiveActivities(projectLiveActivities(src), width);
      expect(lines.every((line) => visibleWidth(line) <= width)).toBe(true);
    }
  });
});
