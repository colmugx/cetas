/**
 * S5A workflow presenter — readable terminal projections of Board workflow
 * data for the cetas transcript.
 *
 * Pure view code: it renders the authoritative `BoardWorkflowView` JSON, the
 * graph proposal preview JSON, and Board Ui confirm prompts as plain lines.
 * It owns no state, makes no decisions, and grants no authority; approvals
 * stay explicit operator choices. Canonical identifiers, the content digest,
 * the board revision, and consequence sentences are rendered verbatim, and
 * long text is wrapped (never truncated) so scrollback keeps the full record.
 * Untrusted task text is sanitized: terminal control characters, including
 * escape sequences and C1 controls, cannot restructure the output.
 */
import {
  stripTerminalSequences,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";

type UnknownRecord = Record<string, unknown>;

const DEFAULT_WIDTH = 80;

/** C0 (tab/CR are normalized first), DEL, C1 controls and BOM. Newline stays. */
const CONTROL_CHARS = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\uFEFF]/g;
const LINE_SEPARATORS = /[\u2028\u2029]/g;

const VIEW_KNOWN_FIELDS = [
  "board",
  "workflow",
  "executions",
  "operation_active",
  "unresolved",
  "mutation_uncertain",
  "stopped",
  "paused",
  "cetas_workflow",
] as const;

const PREVIEW_KNOWN_FIELDS = [
  "proposal_id",
  "digest",
  "workflow_id",
  "parent_task_id",
  "revision",
  "task_count",
  "maximum_edges",
  "tasks",
  "consequence",
] as const;

const SCOPE_KNOWN_FIELDS = [
  "workflow_id",
  "expansion_id",
  "parent",
  "revision",
  "task_ids",
  "consequence",
] as const;

const POLICY_FIELDS = [
  ["max_executions", "max executions"],
  ["max_elapsed_ms", "max elapsed ms"],
  ["execution_timeout_ms", "execution timeout ms"],
  ["max_concurrency", "max concurrency"],
  ["max_expansions", "max expansions"],
  ["max_generated_tasks", "max generated tasks"],
  ["max_depth", "max depth"],
  ["continue_on_confirmed_failure", "continue on confirmed failure"],
] as const;

/** Remove terminal control structure: ANSI/OSC/APC sequences, then C0/C1 leftovers. */
export function sanitizeTerminalText(text: string): string {
  return stripTerminalSequences(text)
    .replace(/\r\n?/g, "\n")
    .replace(/\t/g, "  ")
    .replace(CONTROL_CHARS, "")
    .replace(LINE_SEPARATORS, "\n");
}

/** Render the authoritative `BoardWorkflowView` JSON as readable lines. */
export function renderBoardWorkflowView(view: unknown, width?: number): string[] {
  const w = normalizeWidth(width);
  if (!isRecord(view)) {
    return [
      ...fitLines("Board workflow view unavailable: payload is not an object.", w),
      ...fitLines(stringifyJson(view), w),
    ];
  }
  const board = isRecord(view.board) ? view.board : undefined;
  const run = isRecord(view.workflow) ? view.workflow : undefined;
  const tasks = records(board?.tasks);
  const attempts = records(board?.attempts);
  const expansions = records(board?.expansions);
  const executions = records(view.executions);
  const blocked = records(run?.blocked);
  const preparations = records(run?.partial_preparations);
  const out: string[] = [];

  const rawRevision = board?.revision;
  const revision = typeof rawRevision === "string" || typeof rawRevision === "number"
    ? String(rawRevision)
    : undefined;
  out.push(...fitLines(revision === undefined ? "Board workflow" : `Board workflow · revision ${revision}`, w));

  if (run === undefined) {
    out.push(...fitLines("Workflow none · no workflow run is attached to this board.", w));
  } else {
    out.push(...fitLines(
      `Workflow ${scalar(run.workflow_id)} · phase ${scalar(run.phase)}` +
      ` · stop reason ${prettyOption(run.reason)}`,
      w,
    ));
    const pendingProposal = prettyOption(run.pending_proposal);
    if (pendingProposal !== "none") out.push(...fitLines(`Pending proposal: ${pendingProposal}`, w));
    const expansionPhase = prettyOption(run.expansion_phase);
    if (expansionPhase !== "none") out.push(...fitLines(`Expansion phase: ${expansionPhase}`, w));
  }
  out.push(...fitLines(`Budgets: ${budgetParts(run).join(" · ") || "unavailable"}`, w));
  out.push(...fitLines(`Committed: ${committedParts(run).join(" · ") || "nothing yet"}`, w));
  const scope = listOf(run?.scope).map((id) => scalar(id, "?"));
  out.push(...fitLines(`Scope (${scope.length}): ${scope.join(", ")}`, w));
  out.push(...fitLines(statusLine(view), w));
  const goal = tasks.find(t => scalar(t.id) === scope[0]);
  if (goal) out.push(...fitLines(`Goal: ${scalar(goal.title)}`, w));
  const stages = new Map<string, number>();
  for (const task of tasks) stages.set(scalar(task.stage), (stages.get(scalar(task.stage)) ?? 0) + 1);
  out.push(...fitLines(`Task stages: ${[...stages].map(([stage, n]) => `${stage}=${n}`).join(" · ") || "none"}`, w));
  const running = executions.filter(e => e.phase === "Running").length;
  const owned = executions.filter(e => e.phase !== "Settled" && e.phase !== "Unresolved").length;
  out.push(...fitLines(`Wave: ${owned > 0 ? "owned work active" : "quiescent"} · running Agents ${running} · active owned identities ${owned}`, w));
  const context = isRecord(view.cetas_workflow) ? view.cetas_workflow : undefined;
  if (context) {
    out.push(...fitLines(`Model: ${scalar(context.model)} · effort ${scalar(context.effort)} · ${context.model_pinned === true ? "pinned" : "pins at first composition"}`, w));
    out.push(...fitLines(`Permission: ${scalar(context.permission)} · workspace ${scalar(context.workspace)}`, w));
    out.push(...fitLines(`Maximum concurrency: ${scalar(context.max_concurrency)} · execution timeout ${scalar(context.execution_timeout_ms)} ms`, w));
    out.push(...fitLines(`Planning tools: ${scalar(context.planning_tools)} · execution tools: ${scalar(context.execution_tools)}`, w));
  }

  out.push(...fitLines(`Tasks (${tasks.length}):`, w));
  if (tasks.length === 0) out.push(...fitLines("  none", w));
  for (const task of tasks) {
    out.push(...fitLines(
      `[${scalar(task.id, "?")}] ${scalar(task.title, "")}` +
      ` · stage ${scalar(task.stage, "?")}` +
      ` · execution authorized: ${flag(task.execution_authorized) ? "yes" : "no"}`,
      w,
      "  ",
    ));
    if (typeof task.description === "string" && task.description.length > 0) out.push(...fitLines(`Untrusted description: ${task.description}`, w, "    "));
    if (typeof task.priority === "string") out.push(...fitLines(`Priority: ${task.priority}`, w, "    "));
    for (const item of listOf(task.definition_of_done)) out.push(...fitLines(`Evidence to verify (DoD): ${scalar(item)}`, w, "    "));
    const dependencies = listOf(task.dependencies).map((id) => scalar(id, "?"));
    out.push(...fitLines(
      dependencies.length > 0 ? `depends on: ${dependencies.join(", ")}` : "depends on: none",
      w,
      "    ",
    ));
  }

  out.push(...fitLines(`Attempts (${attempts.length}):`, w));
  if (attempts.length === 0) out.push(...fitLines("  none", w));
  for (const attempt of attempts) {
    out.push(...fitLines(
      `[${scalar(attempt.id, "?")}] task ${scalar(attempt.task_id, "?")}` +
      ` · kind ${scalar(attempt.kind, "?")} · status ${scalar(attempt.status, "?")}` +
      ` · Review decision ${attempt.review === undefined ? "not reported" : prettyOption(attempt.review)}`,
      w,
      "  ",
    ));
  }

  out.push(...fitLines(`Graph expansions (${expansions.length}):`, w));
  if (expansions.length === 0) out.push(...fitLines("  none", w));
  for (const expansion of expansions) {
    out.push(...fitLines(
      `[${scalar(expansion.id, "?")}] workflow ${scalar(expansion.workflow_id, "?")}` +
      ` · parent ${scalar(expansion.parent, "?")}`,
      w,
      "  ",
    ));
    const mapping = records(expansion.mapping)
      .map((entry) => `${scalar(entry.key, "?")} → ${scalar(entry.task_id, "?")}`);
    out.push(...fitLines(mapping.length > 0 ? `mapping: ${mapping.join(" · ")}` : "mapping: none", w, "    "));
  }

  out.push(...fitLines(`Agent executions (${executions.length}):`, w));
  if (executions.length === 0) out.push(...fitLines("  none", w));
  for (const execution of executions) {
    out.push(...fitLines(
      `[${scalar(execution.execution_id, "?")}] task ${scalar(execution.task_id, "?")}` +
      ` · attempt ${scalar(execution.attempt_id, "?")}` +
      ` · session ${scalar(execution.session_id, "?")}` +
      ` · phase ${scalar(execution.phase, "?")}` +
      ` · outcome ${prettyOption(execution.outcome)}`,
      w,
      "  ",
    ));
  }

  out.push(...fitLines(`Blocked tasks (${blocked.length}):`, w));
  if (blocked.length === 0) out.push(...fitLines("  none", w));
  for (const blocker of blocked) {
    const reasons = listOf(blocker.reasons).map((reason) => scalar(reason, "?"));
    out.push(...fitLines(`${scalar(blocker.task_id, "?")}: ${reasons.join(" · ")}`, w, "  "));
  }

  out.push(...fitLines(`Partial preparations (${preparations.length}):`, w));
  if (preparations.length === 0) out.push(...fitLines("  none", w));
  for (const preparation of preparations) {
    out.push(...fitLines(
      `task ${scalar(preparation.task_id, "?")} · attempt ${scalar(preparation.attempt_id, "?")}` +
      ` · step ${scalar(preparation.step, "?")}` +
      ` · uncertain ${flag(preparation.uncertain) ? "yes" : "no"}`,
      w,
      "  ",
    ));
  }

  for (const [key, value] of Object.entries(view)) {
    if ((VIEW_KNOWN_FIELDS as readonly string[]).includes(key)) continue;
    out.push(...fitLines(`${key}: ${stringifyJson(value)}`, w));
  }
  if (attempts.length > 0 || executions.length > 0) {
    out.push(...fitLines(
      "Distinctions: a task is board work · an attempt is one run of a task" +
      " · an execution is the agent session bound to an attempt.",
      w,
    ));
  }
  for (const step of nextStepLines(view, run, tasks, attempts, expansions, blocked)) {
    out.push(...fitLines(`- ${step}`, w));
  }
  return out;
}

/** Render the graph proposal preview JSON (command output, not a decision). */
export function renderProposalPreview(preview: unknown, width?: number): string[] {
  const w = normalizeWidth(width);
  if (!isRecord(preview)) {
    return [
      ...fitLines("Graph proposal preview unavailable: payload is not an object.", w),
      ...fitLines(stringifyJson(preview), w),
    ];
  }
  return renderGraphProposal(preview, {
    width: w,
    heading: "Graph proposal preview — not committed",
    closing:
      "Next steps: /board.workflow.graph.approve commits exactly this graph;" +
      " /board.workflow.graph.reject discards it.",
  });
}

/**
 * Render a Board Ui confirm prompt. The three JSON-bearing Board prompts
 * (graph approval, execution scope approval, start policy) become structured
 * panels; every canonical id, the digest, the revision and the consequence
 * sentence stay verbatim. Any other prompt passes through sanitized and
 * wrapped. Rendering never decides: yes/no stays with the operator.
 */
export function renderBoardConfirmPrompt(prompt: string, width?: number): string[] {
  const w = normalizeWidth(width);
  const clean = sanitizeTerminalText(String(prompt));
  const newlineAt = clean.indexOf("\n");
  const head = newlineAt === -1 ? clean : clean.slice(0, newlineAt);
  const rest = newlineAt === -1 ? "" : clean.slice(newlineAt + 1);

  if (head.startsWith("GRAPH APPROVAL")) {
    const parsed = parseJsonObject(extractJsonObject(rest));
    if (parsed !== null) {
      return renderGraphProposal(parsed, {
        width: w,
        heading: head,
        closing:
          "Reply yes — commits exactly this proposal, atomically." +
          " Reply no — does not commit; no tasks are created. The proposal stays pending until explicit rejection or approval.",
      });
    }
  } else if (head.startsWith("EXECUTION SCOPE APPROVAL")) {
    const parsed = parseJsonObject(extractJsonObject(rest));
    if (parsed !== null) return renderScopeApproval(parsed, head, w);
  } else if (head.startsWith("Start bounded workflow")) {
    const braceAt = clean.indexOf("{");
    const parsed = braceAt >= 0 ? parseJsonObject(extractJsonObject(clean.slice(braceAt))) : null;
    if (parsed !== null) {
      const question = head.slice(0, Math.max(0, Math.min(braceAt, head.length))).trim();
      return renderStartPolicy(parsed, question.length > 0 ? question : head.trim(), rest, w);
    }
  }
  return [...fitLines(head, w), ...fitLines(rest, w)];
}

function renderGraphProposal(
  proposal: UnknownRecord,
  options: { width: number; heading: string; closing: string },
): string[] {
  const out: string[] = [];
  out.push(...fitLines(options.heading, options.width));
  out.push(...fitLines(
    `Proposal ${scalar(proposal.proposal_id)} · workflow ${scalar(proposal.workflow_id)}` +
    ` · parent ${scalar(proposal.parent_task_id)} · board revision ${scalar(proposal.revision)}`,
    options.width,
  ));
  const digest = text(proposal.digest);
  if (digest !== undefined) {
    out.push(...fitLines("Digest (exact proposal content):", options.width));
    out.push(...fitLines(digest, options.width));
  }
  const tasks = records(proposal.tasks);
  const edges = count(proposal.maximum_edges);
  out.push(...fitLines(
    `${count(proposal.task_count) ?? tasks.length} tasks` +
    (edges === undefined ? "" : ` · up to ${edges} edges`),
    options.width,
  ));
  out.push(...fitLines(`Proposed dependency edges: ${tasks.reduce((n, task) => n + listOf(task.depends_on).length, 0)}`, options.width));
  out.push(...fitLines("Tasks:", options.width));
  if (tasks.length === 0) out.push(...fitLines("  none", options.width));
  tasks.forEach((task, index) => {
    out.push(...fitLines(
      `${index + 1}. [${scalar(task.key, "?")}] ${scalar(task.title, "")}` +
      ` · priority ${scalar(task.priority, "?")}`,
      options.width,
      "  ",
    ));
    const description = text(task.description);
    if (description !== undefined) {
      out.push(...fitLines(`description: ${description}`, options.width, "     "));
    }
    const doneItems = listOf(task.definition_of_done).map((item) => scalar(item, "?"));
    if (doneItems.length === 0) {
      out.push(...fitLines("Definition of done: none", options.width, "     "));
    } else {
      out.push(...fitLines("Definition of done:", options.width, "     "));
      for (const item of doneItems) out.push(...fitLines(`- ${item}`, options.width, "       "));
    }
    const dependencies = listOf(task.depends_on).map((dependency) => describeDependency(dependency));
    out.push(...fitLines(
      dependencies.length > 0 ? `Depends on: ${dependencies.join(" · ")}` : "Depends on: none",
      options.width,
      "     ",
    ));
  });
  const consequence = text(proposal.consequence);
  if (consequence !== undefined) out.push(...fitLines(`Consequence: ${consequence}`, options.width));
  for (const [key, value] of Object.entries(proposal)) {
    if ((PREVIEW_KNOWN_FIELDS as readonly string[]).includes(key)) continue;
    out.push(...fitLines(`${key}: ${stringifyJson(value)}`, options.width));
  }
  out.push(...fitLines(options.closing, options.width));
  return out;
}

function renderScopeApproval(scope: UnknownRecord, heading: string, width: number): string[] {
  const out: string[] = [];
  out.push(...fitLines(heading, width));
  out.push(...fitLines(
    `Workflow ${scalar(scope.workflow_id)} · expansion ${scalar(scope.expansion_id)}` +
    ` · parent ${scalar(scope.parent)} · board revision ${scalar(scope.revision)}`,
    width,
  ));
  const ids = listOf(scope.task_ids).map((id) => scalar(id, "?"));
  out.push(...fitLines(
    ids.length > 0
      ? `Task ids this decision authorizes (${ids.length}, exact):`
      : "Task ids this decision authorizes: none",
    width,
  ));
  for (const id of ids) out.push(...fitLines(`- ${id}`, width, "  "));
  const consequence = text(scope.consequence);
  if (consequence !== undefined) out.push(...fitLines(`Consequence: ${consequence}`, width));
  for (const [key, value] of Object.entries(scope)) {
    if ((SCOPE_KNOWN_FIELDS as readonly string[]).includes(key)) continue;
    out.push(...fitLines(`${key}: ${stringifyJson(value)}`, width));
  }
  out.push(...fitLines(
    "Reply yes — authorizes exactly these task ids for execution scope." +
    " Reply no — denies; committed tasks stay outside scope.",
    width,
  ));
  return out;
}

function renderStartPolicy(
  policy: UnknownRecord,
  question: string,
  trailing: string,
  width: number,
): string[] {
  const out: string[] = [];
  out.push(...fitLines(question, width));
  out.push(...fitLines("Budgets for this run (exact):", width));
  const parts = POLICY_FIELDS.map(([key, label]) => `${label}: ${scalar(policy[key], "unavailable")}`);
  out.push(...fitLines(parts.join(" · "), width));
  if (trailing.length > 0) out.push(...fitLines(trailing, width));
  const known = new Set<string>(POLICY_FIELDS.map(([key]) => key));
  for (const [key, value] of Object.entries(policy)) {
    if (known.has(key)) continue;
    out.push(...fitLines(`${key}: ${stringifyJson(value)}`, width));
  }
  out.push(...fitLines(
    "Reply yes — starts the run with exactly these budgets. Reply no — starts nothing.",
    width,
  ));
  return out;
}

function nextStepLines(
  view: UnknownRecord,
  run: UnknownRecord | undefined,
  tasks: UnknownRecord[],
  attempts: UnknownRecord[],
  expansions: UnknownRecord[],
  blocked: UnknownRecord[],
): string[] {
  const steps: string[] = [];
  const proposal = scalar(run?.pending_proposal, "None");
  const pendingProposal = proposal !== "None" && proposal !== "";
  if (run === undefined) {
    steps.push(tasks.length > 0
      ? "No run is attached: /board.workflow.start creates one and confirms its budgets first."
      : "Start a bounded workflow with /board.workflow.start; it confirms its budgets before anything runs.");
  } else {
    if (pendingProposal) {
      steps.push(
        "A graph proposal is pending: /board.workflow.preview shows it," +
        " /board.workflow.graph.approve commits it exactly," +
        " /board.workflow.graph.reject discards it.");
    }
    if (attempts.length > 0) {
      steps.push(
        "/board.workflow.prepare queues an Execute attempt with trusted input;" +
        " /board.workflow.run runs the next eligible wave;" +
        " /board.workflow.wait waits for it to settle.");
    }
    if (expansions.length > 0) {
      steps.push(
        "Committed expansions need separate scope:" +
        " /board.workflow.scope.approve authorizes the exact task set," +
        " /board.workflow.scope.reject denies it.");
    }
    if (blocked.length > 0) {
      steps.push(
        "Blocked tasks stay blocked until their reasons clear;" +
        " /board.workflow.run only ever runs the eligible wave.");
    }
  }
  if (flag(view.unresolved) || flag(view.mutation_uncertain)) {
    steps.push("Something is unresolved or uncertain: /board.workflow.reconcile is a read-only check.");
  }
  if (flag(view.paused)) {
    steps.push("Admission is paused: /board.workflow.resume re-opens it without dispatching new work.");
  }
  if (flag(view.stopped)) {
    steps.push("Stop was requested: the run finishes its current wave and admits nothing new.");
  }
  if (steps.length === 0) {
    steps.push("Nothing is pending; /board.workflow.status refreshes this view.");
  }
  return steps.slice(0, 6);
}

function statusLine(view: UnknownRecord): string {
  const statuses: string[] = [];
  if (flag(view.operation_active)) statuses.push("operation active");
  if (flag(view.unresolved)) statuses.push("unresolved");
  if (flag(view.mutation_uncertain)) statuses.push("mutation uncertain");
  if (flag(view.stopped)) statuses.push("stop requested");
  if (flag(view.paused)) statuses.push("paused");
  return statuses.length > 0
    ? `Status: ${statuses.join(" · ")}`
    : "Status: idle — no active operation, nothing unresolved, not paused";
}

function budgetParts(run: UnknownRecord | undefined): string[] {
  if (run === undefined) return [];
  const parts: string[] = [];
  const remaining = (label: string, value: unknown) => {
    const amount = count(value);
    if (amount !== undefined) parts.push(`${amount} ${label} left`);
  };
  remaining("executions", run.remaining_executions);
  const ms = count(run.remaining_ms) ?? milliseconds(run.remaining_ms);
  if (ms !== undefined) parts.push(`${ms}ms left`);
  remaining("expansions", run.remaining_expansions);
  remaining("generated tasks", run.remaining_generated_tasks);
  return parts;
}

function committedParts(run: UnknownRecord | undefined): string[] {
  if (run === undefined) return [];
  const parts: string[] = [];
  const committed = (label: string, value: unknown) => {
    const amount = count(value);
    if (amount !== undefined) parts.push(`${amount} ${label}`);
  };
  committed("generated tasks", run.generated_tasks);
  committed("expansions", run.expansions_committed);
  committed("scope authorizations", run.scope_authorizations);
  committed("settled executions", run.settled_executions);
  return parts;
}

function describeDependency(dependency: unknown): string {
  if (isRecord(dependency)) {
    if ("local" in dependency) return `${scalar(dependency.local, "?")} (proposal-local)`;
    if ("existing" in dependency) return `${scalar(dependency.existing, "?")} (existing board task)`;
  }
  return scalar(dependency, "?");
}

/** Display width in terminal columns; clamped so wrapping always terminates. */
function normalizeWidth(width?: number): number {
  const candidate = typeof width === "number" && Number.isFinite(width) ? Math.floor(width) : DEFAULT_WIDTH;
  return Math.max(1, candidate);
}

/**
 * Wrap one (already control-free) text block to `width` columns, prefixing
 * every row with `indent`. Truncation never happens: rows that still overflow
 * (single graphemes wider than the width) are re-packed by grapheme instead.
 */
function fitLines(text: string, width: number, indent = ""): string[] {
  const clean = sanitizeTerminalText(text);
  // The indent lives inside the width budget: `indent + row` must never
  // exceed `width`. An indent wider than the terminal is clipped, and it is
  // dropped entirely when less than two content columns would remain —
  // nesting decoration is worthless there and would only widen overflow.
  let indentWidth = Math.min(visibleWidth(indent), Math.max(0, width - 1));
  if (width - indentWidth < 2) indentWidth = 0;
  const pad = " ".repeat(indentWidth);
  const effective = Math.max(1, width - indentWidth);
  const lines: string[] = [];
  for (const rawLine of clean.split("\n")) {
    const wrapped = wrapTextWithAnsi(rawLine, effective);
    for (const row of wrapped.length > 0 ? wrapped : [rawLine]) {
      for (const fitted of hardWrapRow(row, effective)) lines.push(`${pad}${fitted}`.trimEnd());
    }
  }
  return lines.length > 0 ? lines : [pad.trimEnd()];
}

function hardWrapRow(line: string, width: number): string[] {
  if (visibleWidth(line) <= width) return [line];
  const rows: string[] = [];
  let row = "";
  let rowWidth = 0;
  for (const { segment } of new Intl.Segmenter().segment(line)) {
    const segmentWidth = visibleWidth(segment);
    if (rowWidth > 0 && rowWidth + segmentWidth > width) {
      rows.push(row);
      row = "";
      rowWidth = 0;
    }
    row += segment;
    rowWidth += segmentWidth;
  }
  if (row.length > 0) rows.push(row);
  return rows.length > 0 ? rows : [line];
}

/** First balanced JSON object in `text` (string- and escape-aware), or null. */
function extractJsonObject(text: string): string | null {
  const start = text.indexOf("{");
  if (start === -1) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const char = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === "{") depth++;
    else if (char === "}") {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

function parseJsonObject(raw: string | null): UnknownRecord | null {
  if (raw === null) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function count(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function flag(value: unknown): boolean {
  return value === true;
}

function listOf(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function records(value: unknown): UnknownRecord[] {
  return listOf(value).filter(isRecord);
}

function scalar(value: unknown, fallback?: string): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "bigint") return String(value);
  if (value === true) return "true";
  if (value === false) return "false";
  return fallback ?? "none";
}

/** `None`/`Some(X)` debug-repr option strings become `none`/`X`. */
function prettyOption(value: unknown): string {
  const raw = scalar(value, "None");
  if (raw === "None" || raw === "") return "none";
  if (raw.startsWith("Some(") && raw.endsWith(")")) return raw.slice(5, -1);
  return raw;
}

function milliseconds(value: unknown): number | undefined {
  const raw = text(value);
  if (raw === undefined) return undefined;
  const parsed = Number(raw);
  return raw !== "" && Number.isFinite(parsed) ? parsed : undefined;
}

function stringifyJson(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "null";
  } catch {
    return String(value);
  }
}
