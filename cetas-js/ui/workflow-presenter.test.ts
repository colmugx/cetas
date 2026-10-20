/**
 * Terminal contract tests for the S5A workflow presenter: width safety under
 * Unicode, control-character sanitization, and verbatim preservation of the
 * canonical ids, digest, revision and consequence sentences the Board
 * extension puts on the wire.
 */
import { describe, expect, test } from "bun:test";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import {
  renderBoardConfirmPrompt,
  renderBoardWorkflowView,
  renderProposalPreview,
  sanitizeTerminalText,
} from "./workflow-presenter.ts";

const DIGEST = "sha256:e055c09e90b23c397fd9ab9658bcaeb6e8a90ff10c57a2c899bd56af00c1c1e5";

const previewFixture = {
  proposal_id: "proposal-board-3",
  digest: DIGEST,
  workflow_id: "workflow-w1",
  parent_task_id: "task-root",
  revision: "12",
  task_count: 2,
  maximum_edges: 60,
  tasks: [
    {
      key: "work",
      title: "验证任务 🚀 with a deliberately long description that must wrap instead of vanish",
      description: "Untrusted task data, never authorization.",
      priority: "normal",
      definition_of_done: ["Evidence inspected", "证据已审查"],
      depends_on: [{ existing: "task-root" }],
    },
    {
      key: "verify",
      title: "Verify implementation",
      description: "",
      priority: "high",
      definition_of_done: [],
      depends_on: [{ local: "work" }],
    },
  ],
  consequence:
    "Commit complete additive graph only. Created tasks have no attempts or execution authorization. No resource budget is increased.",
};

const viewFixture = {
  board: {
    revision: "12",
    tasks: [
      {
        id: "task-1",
        title: "Validate the Board contract",
        stage: "Created",
        dependencies: ["task-2", "task-3"],
        execution_authorized: false,
      },
      {
        id: "task-2",
        title: "验证 task",
        stage: "Running",
        dependencies: [],
        execution_authorized: true,
      },
    ],
    attempts: [
      { id: "attempt-9", task_id: "task-1", kind: "Execute", status: "Running" },
    ],
    expansions: [
      {
        id: "expansion-7",
        workflow_id: "workflow-w1",
        parent: "task-root",
        mapping: [
          { key: "plan-step-2", task_id: "task-1" },
          { key: "plan-step-3", task_id: "task-2" },
        ],
      },
    ],
  },
  workflow: {
    workflow_id: "workflow-w1",
    phase: "Running",
    reason: "Some(DeadlineReached)",
    scope_size: 2,
    scope: ["task-1", "task-2"],
    remaining_executions: 3,
    remaining_ms: "54000",
    settled_executions: 1,
    remaining_expansions: 2,
    remaining_generated_tasks: 13,
    generated_tasks: 7,
    expansions_committed: 1,
    scope_authorizations: 2,
    pending_proposal: "Some(proposal-board-3)",
    expansion_phase: "Some(AwaitingApproval)",
    partial_preparations: [
      { task_id: "task-2", attempt_id: "attempt-10", step: "QueueExecute", uncertain: true },
    ],
    blocked: [
      { task_id: "task-4", reasons: ['MissingDependency("task-2")'] },
    ],
  },
  operation_active: true,
  unresolved: false,
  mutation_uncertain: true,
  stopped: false,
  paused: false,
  executions: [
    {
      task_id: "task-1",
      attempt_id: "attempt-9",
      execution_id: "execution-e1",
      session_id: "session-s1",
      phase: "Running",
      outcome: "None",
    },
  ],
};

const graphPrompt =
  "GRAPH APPROVAL — commit exactly this proposal?\n" +
  JSON.stringify(previewFixture, null, 2);

const scopePrompt =
  "EXECUTION SCOPE APPROVAL — separate from graph approval\n" +
  JSON.stringify({
    workflow_id: "workflow-w1",
    expansion_id: "expansion-7",
    parent: "task-root",
    revision: "12",
    task_ids: ["task-1", "task-2"],
    consequence:
      "Authorize this exact committed task set for execution scope. No attempts are queued; no budget is added.",
  }, null, 2);

const startPrompt =
  'Start bounded workflow? {"max_executions":4,"max_elapsed_ms":60000,"execution_timeout_ms":10000,' +
  '"max_concurrency":1,"max_expansions":2,"max_generated_tasks":20,"max_depth":3,' +
  '"continue_on_confirmed_failure":false}' +
  "\nGraph creation, execution scope and each task input still require separate approval.";

const WIDTHS = [1, 2, 3, 7, 8, 19, 20, 39, 40, 79, 80, 120, 200];

/** Whitespace-insensitive view of rendered output (wrap points consume spaces). */
function collapse(value: string): string {
  return value.replace(/\s+/g, "");
}

/** All rendered rows stay inside the display width, including CJK and emoji. */
function expectWidthSafe(lines: string[], width: number, tolerance = 0): void {
  for (const line of lines) {
    expect(visibleWidth(line), JSON.stringify(line)).toBeLessThanOrEqual(width + tolerance);
  }
}

/**
 * Wrap may break words, but it may never add, drop or replace characters:
 * every non-whitespace character of `needle` must survive into the rows.
 */
function expectContent(lines: string[], needle: string): void {
  expect(collapse(lines.join("\n"))).toContain(collapse(needle));
}

function expectCleanText(lines: string[]): void {
  const text = lines.join("\n");
  expect(text).not.toMatch(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/);
  expect(stripTerminalSequences(text)).toBe(text);
}

describe("sanitizeTerminalText", () => {
  test("strips escape sequences, C1 controls and DEL while keeping text", () => {
    expect(sanitizeTerminalText("a\x1b[31mred\x1b[0mb")).toBe("aredb");
    expect(sanitizeTerminalText("x\u009b31mY")).toBe("x31mY");
    expect(sanitizeTerminalText("del\u007Fete")).toBe("delete");
    expect(sanitizeTerminalText("nul\u0000uil")).toBe("nuluil");
    expect(sanitizeTerminalText("hide\x1b]8;;http://x\u0007link\x1b\\!")).toBe("hidelink\\!");
  });

  test("normalizes CR and tabs, keeps newlines and printable Unicode", () => {
    expect(sanitizeTerminalText("a\r\nb\rc")).toBe("a\nb\nc");
    expect(sanitizeTerminalText("a\tb")).toBe("a  b");
    expect(sanitizeTerminalText("中文🚀café\nok")).toBe("中文🚀café\nok");
    expect(sanitizeTerminalText("sep\u2028line")).toBe("sep\nline");
  });
});

describe("renderBoardWorkflowView", () => {
  test("renders tasks, attempts, executions, budgets, blockers and next steps", () => {
    const lines = renderBoardWorkflowView(viewFixture, 100);
    expectContent(lines, "Board workflow · revision 12");
    expectContent(lines, "Workflow workflow-w1 · phase Running · stop reason DeadlineReached");
    expectContent(lines, "3 executions left");
    expectContent(lines, "54000ms left");
    expectContent(lines, "2 expansions left");
    expectContent(lines, "13 generated tasks left");
    expectContent(lines, "Scope (2): task-1, task-2");
    expectContent(lines, "[task-1] Validate the Board contract · stage Created · execution authorized: no");
    expectContent(lines, "depends on: task-2, task-3");
    expectContent(lines, "[task-2] 验证 task · stage Running · execution authorized: yes");
    expectContent(lines, "[attempt-9] task task-1 · kind Execute · status Running");
    expectContent(lines, "[expansion-7] workflow workflow-w1 · parent task-root");
    expectContent(lines, "plan-step-2 → task-1 · plan-step-3 → task-2");
    expectContent(lines, "[execution-e1] task task-1 · attempt attempt-9 · session session-s1 · phase Running · outcome none");
    expectContent(lines, 'task-4: MissingDependency("task-2")');
    expectContent(lines, "task task-2 · attempt attempt-10 · step QueueExecute · uncertain yes");
    expectContent(lines, "Status: operation active · mutation uncertain");
    expectContent(lines, "agent session bound to an attempt");
    // Uncertain state must not recommend a graph mutation or new admission.
    expect(lines.join(" ")).not.toContain("/board.workflow.graph.approve");
    expect(lines.join(" ")).not.toContain("/board.workflow.scope.approve");
    expectContent(lines, "/board.workflow.reconcile");
  });

  test("keeps every canonical id, budget and reason in scrollback at any width", () => {
    const required = [
      "task-1", "task-2", "task-4", "attempt-9", "attempt-10",
      "expansion-7", "workflow-w1", "execution-e1", "session-s1", "proposal-board-3",
      "DeadlineReached", 'MissingDependency("task-2")', "Validate the Board contract", "验证 task",
    ];
    for (const width of WIDTHS) {
      const lines = renderBoardWorkflowView(viewFixture, width);
      expectWidthSafe(lines, width, width <= 1 ? 1 : 0);
      expectCleanText(lines);
      for (const needle of required) expectContent(lines, needle);
    }
  });

  test("an empty board states what is absent instead of omitting sections", () => {
    const lines = renderBoardWorkflowView({
      board: { revision: "0", tasks: [], attempts: [], expansions: [] },
      workflow: null,
      executions: [],
      operation_active: false,
      unresolved: false,
      mutation_uncertain: false,
      stopped: false,
      paused: false,
    }, 80);
    expectContent(lines, "Board workflow · revision 0");
    expectContent(lines, "Tasks (0):");
    expectContent(lines, "Attempts (0):");
    expectContent(lines, "none");
    expectContent(lines, "Status: idle — no active operation, nothing unresolved, not paused");
    expectContent(lines, "/board.workflow.start");
  });

  test("unknown payload fields are shown, not silently dropped", () => {
    const lines = renderBoardWorkflowView({ ...viewFixture, surprise: { a: 1 } }, 80);
    expectContent(lines, 'surprise: {"a":1}');
  });

  test("malformed payloads degrade to a readable failure", () => {
    for (const payload of [null, 42, "nope", [1, 2]]) {
      const lines = renderBoardWorkflowView(payload, 80);
      expectContent(lines, "Board workflow view unavailable");
      expect(lines.join("\n")).not.toContain("undefined");
    }
  });
});

describe("renderProposalPreview", () => {
  test("shows digest, ids, every task and DoD item, and the consequence verbatim", () => {
    const lines = renderProposalPreview(previewFixture, 100);
    expectContent(lines, DIGEST);
    expectContent(lines, "Proposal proposal-board-3 · workflow workflow-w1 · parent task-root · board revision 12");
    expectContent(lines, "2 tasks · up to 60 edges");
    expectContent(lines, "[work] 验证任务 🚀");
    expectContent(lines, "Evidence inspected");
    expectContent(lines, "证据已审查");
    expectContent(lines, "Definition of done: none");
    expectContent(lines, "task-root (existing board task)");
    expectContent(lines, "work (proposal-local)");
    expectContent(lines, `Consequence: ${previewFixture.consequence}`);
    expectContent(lines, "/board.workflow.graph.approve");
    expectContent(lines, "/board.workflow.graph.reject");
  });

  test("the exact digest survives every width without added characters", () => {
    for (const width of WIDTHS) {
      const lines = renderProposalPreview(previewFixture, width);
      expectWidthSafe(lines, width, width <= 1 ? 1 : 0);
      expectCleanText(lines);
      expectContent(lines, DIGEST);
      expectContent(lines, previewFixture.consequence);
      expectContent(lines, "证据已审查");
      expectContent(lines, "Untrusted task data, never authorization.");
    }
    // From 71+ columns on, the digest also sits unbroken on its own row.
    expect(renderProposalPreview(previewFixture, 100).join("\n")).toContain(DIGEST);
  });

  test("malformed payloads degrade to a readable failure", () => {
    const lines = renderProposalPreview("nope", 80);
    expectContent(lines, "Graph proposal preview unavailable");
  });
});

describe("renderBoardConfirmPrompt", () => {
  test("graph approval keeps the exact digest, revision, ids and consequence", () => {
    const lines = renderBoardConfirmPrompt(graphPrompt, 100);
    expect(lines[0]).toBe("GRAPH APPROVAL — commit exactly this proposal?");
    expectContent(lines, DIGEST);
    expectContent(lines, "board revision 12");
    expectContent(lines, "Proposal proposal-board-3");
    expectContent(lines, "workflow workflow-w1");
    expectContent(lines, "parent task-root");
    expectContent(lines, "[work] 验证任务 🚀");
    expectContent(lines, "- Evidence inspected");
    expectContent(lines, `Consequence: ${previewFixture.consequence}`);
    expectContent(lines, "Reply yes");
    expectContent(lines, "Reply no");
    expectContent(lines, "The proposal stays pending until explicit rejection or approval.");
    expect(lines.join(" ")).not.toContain("discards it");
  });

  test("execution scope approval keeps every canonical task id and consequence", () => {
    const lines = renderBoardConfirmPrompt(scopePrompt, 80);
    expect(lines[0]).toBe("EXECUTION SCOPE APPROVAL — separate from graph approval");
    expectContent(lines, "Workflow workflow-w1 · expansion expansion-7");
    expectContent(lines, "board revision 12");
    expectContent(lines, "- task-1");
    expectContent(lines, "- task-2");
    expectContent(lines, "Consequence: Authorize this exact committed task set for execution scope.");
    expectContent(lines, "Reply yes");
  });

  test("start policy renders each budget field with its exact value", () => {
    const lines = renderBoardConfirmPrompt(startPrompt, 80);
    expectContent(lines, "Start bounded workflow?");
    expectContent(lines, "max executions: 4");
    expectContent(lines, "max elapsed ms: 60000");
    expectContent(lines, "execution timeout ms: 10000");
    expectContent(lines, "max concurrency: 1");
    expectContent(lines, "max expansions: 2");
    expectContent(lines, "max generated tasks: 20");
    expectContent(lines, "max depth: 3");
    expectContent(lines, "continue on confirmed failure: false");
    expectContent(lines, "Graph creation, execution scope and each task input still require separate approval.");
    expect(lines.join("\n")).not.toContain('{"max_executions"');
  });

  test("hostile task text cannot inject terminal control structure", () => {
    const hostile = {
      ...previewFixture,
      tasks: [{
        ...previewFixture.tasks[0],
        title: "\x1b[31mred\u009b2Jtitle",
      }],
    };
    const lines = renderBoardConfirmPrompt(
      "GRAPH APPROVAL — commit exactly this proposal?\n" + JSON.stringify(hostile, null, 2),
      80,
    );
    expectCleanText(lines);
    expectContent(lines, "red2Jtitle");
  });

  test("unparseable graph prompts fall back to the full sanitized text", () => {
    const broken = "GRAPH APPROVAL — commit exactly this proposal?\nnot json { oops";
    const lines = renderBoardConfirmPrompt(broken, 40);
    expectContent(lines, "GRAPH APPROVAL — commit exactly this proposal?");
    expectContent(lines, "not json { oops");
  });

  test("other Board prompts pass through wrapped and width-safe", () => {
    const prompt =
      "Run the next eligible wave using only separately authorized task inputs and remaining budgets?" +
      " Task success never automatically means Done.";
    for (const width of WIDTHS) {
      const lines = renderBoardConfirmPrompt(prompt, width);
      expectWidthSafe(lines, width, width <= 1 ? 1 : 0);
      expectContent(lines, "Task success never automatically means Done.");
    }
  });
});

describe("presenter purity and terminal hygiene", () => {
  test("rendering is deterministic and holds no state", () => {
    expect(renderBoardWorkflowView(viewFixture, 80)).toEqual(renderBoardWorkflowView(viewFixture, 80));
    expect(renderProposalPreview(previewFixture, 80)).toEqual(renderProposalPreview(previewFixture, 80));
    expect(renderBoardConfirmPrompt(graphPrompt, 80)).toEqual(renderBoardConfirmPrompt(graphPrompt, 80));
  });

  test("every renderer stays width-safe and control-free at every width", () => {
    for (const width of WIDTHS) {
      // At one column a single wide glyph (CJK/emoji) cannot fit any row; the
      // presenter keeps it whole on its own row, so allow one column there.
      const tolerance = width <= 1 ? 1 : 0;
      expectWidthSafe(renderBoardWorkflowView(viewFixture, width), width, tolerance);
      expectWidthSafe(renderProposalPreview(previewFixture, width), width, tolerance);
      expectWidthSafe(renderBoardConfirmPrompt(graphPrompt, width), width, tolerance);
      expectWidthSafe(renderBoardConfirmPrompt(scopePrompt, width), width, tolerance);
      expectWidthSafe(renderBoardConfirmPrompt(startPrompt, width), width, tolerance);
      expectCleanText(renderBoardWorkflowView(viewFixture, width));
      expectCleanText(renderProposalPreview(previewFixture, width));
      expectCleanText(renderBoardConfirmPrompt(graphPrompt, width));
    }
  });
});

test("product overview separates pinned host context, stage counts, evidence and Review", () => {
  const lines = renderBoardWorkflowView({
    ...viewFixture,
    board: { ...viewFixture.board,
      tasks: [{ ...viewFixture.board.tasks[0], description: "Untrusted implementation note", priority: "high", definition_of_done: ["Run independent tests"] }, viewFixture.board.tasks[1]],
      attempts: [{ ...viewFixture.board.attempts[0], status: "Succeeded", review: "None" }],
    },
    cetas_workflow: { model: "chosen-provider/chosen-model", effort: "high", model_pinned: true,
      permission: "WorkspaceWrite", workspace: "coding-workspace", max_concurrency: 2,
      execution_timeout_ms: 10000, planning_tools: "none", execution_tools: "scoped tools" },
  }, 100);
  expectContent(lines, "Goal: Validate the Board contract");
  expectContent(lines, "Task stages: Created=1 · Running=1");
  expectContent(lines, "running Agents 1");
  expectContent(lines, "chosen-provider/chosen-model · effort high · pinned");
  expectContent(lines, "Permission: WorkspaceWrite");
  expectContent(lines, "Untrusted description: Untrusted implementation note");
  expectContent(lines, "Evidence to verify (DoD): Run independent tests");
  expectContent(lines, "status Succeeded · Review decision none");
  expectContent(lines, "stage Created · execution authorized: no");
});

test("terminal and unresolved status never recommend new approval or admission", () => {
  const base = { ...viewFixture, operation_active: false, mutation_uncertain: false };
  for (const phase of ["Stopped", "Completed", "Failed", "Unresolved"]) {
    const lines = renderBoardWorkflowView({ ...base, workflow: { ...base.workflow, phase } }, 100);
    expectContent(lines, "This workflow is terminal");
    expect(lines.join(" ")).not.toContain("/board.workflow.run");
    expect(lines.join(" ")).not.toContain("/board.workflow.graph.approve");
    expect(lines.join(" ")).not.toContain("/board.workflow.scope.approve");
    expect(lines.join(" ")).not.toContain("/board.workflow.resume");
  }
  const unresolved = renderBoardWorkflowView({ ...base,
    executions: [{ ...base.executions[0], phase: "Unresolved" }],
  }, 100);
  expectContent(unresolved, "Status: unresolved");
  expectContent(unresolved, "/board.workflow.reconcile is a read-only check");
  expect(unresolved.join(" ")).not.toContain("/board.workflow.run");
});
