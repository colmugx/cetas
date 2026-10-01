/**
 * subagent-header.ts — bounded live header of running background subagents,
 * mounted near the input (never in the transcript body).
 *
 * Shape (approved display plan):
 *     ⚡ 1 agent(apple) · coder 53s · bash
 *     ⚡ 1 agent(banana) · explore 1m · read
 *     ⚡ 3 agents · +2 more
 *
 * Every task line reads `⚡ 1 agent(name)`; the running total appears only
 * in the degraded single count line and the `+N more` aggregate.
 *
 * Bounded by construction: at most `maxTasks` (default 3) task detail rows
 * plus one `+N more` aggregate; a tight terminal height lowers the budget
 * and an extremely short or narrow terminal degrades to a single total
 * count line. Every line is truncated with pi-tui's width-aware helpers so
 * CJK, emoji and ANSI are measured in terminal columns, not characters.
 *
 * Two layers so shells can avoid wasted work:
 * - `projectSubagentHeader()` / `subagentHeaderEquals()`: a pure, comparable
 *   projection (content only — width applied at render). Shells compare the
 *   projection after events and elapsed ticks and skip rebuilds when it has
 *   not changed.
 * - `SubagentHeader`: a pi-tui `Component` that renders the projection for
 *   the current viewport width. It owns no timer — the shell drives `now`
 *   from its own on-demand ticker.
 */

import { type Component, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";
import type { SubagentActivity } from "../src/controllers/subagent-activity.ts";

/** Default cap on task detail rows (before height degradation). */
export const SUBAGENT_HEADER_MAX_TASKS = 3;

/** Below this many columns only the total-count line fits. */
const COUNT_ONLY_WIDTH = 24;

/** One task's display row, pre-composed for cheap equality checks. */
export interface SubagentHeaderEntry {
  /** Stable nickname (apple, …). */
  readonly name: string;
  readonly kind: string;
  /** Compact elapsed: `53s`, `1m`, `2h`. */
  readonly elapsed: string;
  /** Current tool, or the phase word (thinking/finishing). */
  readonly tool: string;
  /** `agent(apple) · coder 53s · bash` — plain text, width applied at render. */
  readonly detail: string;
}

/** Width-independent content of the header — comparable across ticks. */
export interface SubagentHeaderProjection {
  /** Total running background tasks, including unlisted ones. */
  readonly total: number;
  readonly entries: readonly SubagentHeaderEntry[];
  /** Tasks beyond the detail budget (`+N more`). */
  readonly overflow: number;
  /** Detail rows the height budget allows; 0 = count-only degradation. */
  readonly detailBudget: number;
}

/** Inputs for projection; `now` comes from the shell's ticker, not a timer. */
export interface SubagentHeaderOptions {
  readonly now: number;
  /** Terminal rows, when known. */
  readonly height?: number;
  /** Rows the editor/status stack occupies below the header. */
  readonly bottomReserve?: number;
  readonly maxTasks?: number;
}

/** Live source the component re-reads on every render — no caching, no timer. */
export interface SubagentHeaderSource extends SubagentHeaderOptions {
  readonly records: readonly SubagentActivity[];
}

/** Compact elapsed: seconds under a minute, then minutes, then hours. */
export function formatSubagentElapsed(startedAt: number, now: number): string {
  const seconds = Math.max(0, Math.floor((now - startedAt) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h`;
}

/**
 * What the child is doing right now. The current tool when one is in
 * flight; otherwise a short phase word — never the stale `last_tool`
 * posing as ongoing work.
 */
export function subagentPhase(
  record: Pick<SubagentActivity, "current_tool" | "child_turn_state">,
): string {
  if (record.current_tool !== undefined && record.current_tool.length > 0) {
    return record.current_tool;
  }
  return record.child_turn_state !== undefined ? "finishing" : "thinking";
}

/** Detail rows the vertical budget allows; 0 means count-only. */
function detailBudget(options: SubagentHeaderOptions): number {
  const cap = options.maxTasks ?? SUBAGENT_HEADER_MAX_TASKS;
  if (options.height === undefined) return cap;
  const available = Math.max(0, options.height - (options.bottomReserve ?? 0));
  if (available < 3) return 0;
  if (available < 7) return Math.min(cap, 1);
  if (available < 11) return Math.min(cap, 2);
  return cap;
}

/**
 * Project live background records into comparable header content. Input is
 * expected to be the store's live background snapshot; non-background
 * records are skipped defensively. Order follows `seq` (first appearance)
 * and is stable across completions, resumes and list shrinkage.
 */
export function projectSubagentHeader(
  records: readonly SubagentActivity[],
  options: SubagentHeaderOptions,
): SubagentHeaderProjection {
  const live = records
    .filter((record) => record.background === true)
    .sort((a, b) => a.seq - b.seq);
  const budget = detailBudget(options);
  const entries: SubagentHeaderEntry[] = [];
  for (const record of live.slice(0, budget)) {
    const elapsed = formatSubagentElapsed(record.started_at, options.now);
    const tool = subagentPhase(record);
    entries.push({
      name: record.display_name,
      kind: record.kind,
      elapsed,
      tool,
      detail: `agent(${record.display_name}) · ${record.kind} ${elapsed} · ${tool}`,
    });
  }
  return {
    total: live.length,
    entries,
    overflow: Math.max(0, live.length - entries.length),
    detailBudget: budget,
  };
}

/** Field-wise comparison so shells can skip identical projections. */
export function subagentHeaderEquals(
  a: SubagentHeaderProjection,
  b: SubagentHeaderProjection,
): boolean {
  if (a.total !== b.total || a.overflow !== b.overflow) return false;
  if (a.detailBudget !== b.detailBudget) return false;
  if (a.entries.length !== b.entries.length) return false;
  return a.entries.every((entry, index) => {
    const other = b.entries[index]!;
    return (
      entry.name === other.name &&
      entry.kind === other.kind &&
      entry.elapsed === other.elapsed &&
      entry.tool === other.tool &&
      entry.detail === other.detail
    );
  });
}

/**
 * Render a projection into themed lines for the given viewport width.
 * Count-only degradation kicks in for tiny budgets or narrow terminals;
 * `visibleWidth` of every line is guaranteed ≤ width.
 */
export function renderSubagentHeader(
  projection: SubagentHeaderProjection,
  width: number,
): string[] {
  if (width <= 0 || projection.total === 0) return [];
  const label = projection.total === 1 ? "agent" : "agents";
  const countSummary = `⚡ ${projection.total} ${label}`;
  const countLine = (text: string): string =>
    theme.accent(truncateToWidth(text, width));
  if (projection.detailBudget <= 0 || width < COUNT_ONLY_WIDTH) {
    return [countLine(countSummary)];
  }
  const aggregate = `${countSummary} · +${projection.overflow} more`;
  if (projection.overflow > 0 && projection.detailBudget < 2) {
    // One row cannot hold details plus the aggregate: prefer the aggregate.
    return [countLine(aggregate)];
  }
  // Every task line reads `⚡ 1 agent(name) · …` — the total appears only in
  // the degraded count line and the `+N more` aggregate.
  const lines = projection.entries.map((entry) =>
    theme.muted(truncateToWidth(`⚡ 1 ${entry.detail}`, width)),
  );
  if (projection.overflow > 0) {
    lines.push(theme.muted(truncateToWidth(aggregate, width)));
  }
  return lines;
}

/**
 * Live header component. Reads its source on every render (the shell's
 * event/ticker path decides when that is worth a `requestRender`) and never
 * starts timers of its own.
 */
export class SubagentHeader implements Component {
  constructor(private readonly source: () => SubagentHeaderSource | undefined) {}

  render(width: number): string[] {
    const source = this.source();
    if (source === undefined) return [];
    const projection = projectSubagentHeader(source.records, source);
    return renderSubagentHeader(projection, width);
  }

  handleInput(_data: string): void {}

  invalidate(): void {}
}

/** Visible width of a header line (re-exported for shell-side assertions). */
export { visibleWidth as subagentHeaderVisibleWidth };
