/**
 * Live Activities replaces the separate Subagent and Wakeup headers.
 * It is a bounded, ephemeral projection, not a transcript: questions remain
 * visible while outstanding; an answer removes the question immediately.
 * "main answered agent" belongs only to the durable transcript.
 */
import { type Component, truncateToWidth } from "@earendil-works/pi-tui";
import type { SubagentActivity } from "../src/controllers/subagent-activity.ts";
import type { WakeupTicket } from "../src/controllers/wakeup-activity.ts";
import { formatSubagentElapsed, subagentPhase } from "./subagent-header.ts";
import { theme } from "./theme.ts";

export type LiveActivityRole = "agent" | "question" | "user-question" | "wakeup" | "coordination" | "waiting" | "muted";
export type LiveActivityStyle = (role: LiveActivityRole, text: string) => string;

/**
 * One parked non-blocking question (`notify_user`), as the header shows it.
 * Answered/expired questions never reach the header: the store removes them.
 */
export interface PendingUserQuestion {
  readonly id: string;
  /** Short UI form (`@q3`); the header never shows the long id. */
  readonly short_id: string;
  readonly text: string;
  readonly kind: "input" | "confirm" | "select";
  /** Absolute deadline (epoch ms); 0 disables expiry. */
  readonly deadline_at: number;
}

export interface LiveActivitiesSource {
  readonly records: readonly SubagentActivity[];
  readonly wakeups: readonly WakeupTicket[];
  readonly resultsWaiting: number;
  readonly activeDecisions: number;
  /** Questions the human still owes an answer to (never agent-to-agent). */
  readonly userQuestions?: readonly PendingUserQuestion[];
  readonly now: number;
  readonly height?: number;
  readonly bottomReserve?: number;
}

export interface LiveActivityRow {
  readonly key: string;
  readonly role: LiveActivityRole;
  readonly label: string;
}
export interface LiveActivitiesProjection {
  readonly rows: readonly LiveActivityRow[];
  readonly hidden: number;
  readonly total: number;
  readonly countOnly: boolean;
}

const MAX_VISIBLE_ROWS = 4;
const MIN_DETAILS_WIDTH = 24;
const QUESTION_PREVIEW_CHARS = 80;

/** Do not render raw control sequences or unbounded question text in the live header. */
export function questionPreview(raw: string): string {
  const cleaned = raw.replace(/[\x00-\x1f\x7f-\x9f]/g, " ").replace(/\s+/g, " ").trim();
  const chars = Array.from(cleaned);
  const prefix = chars.slice(0, QUESTION_PREVIEW_CHARS).join("");
  return chars.length > QUESTION_PREVIEW_CHARS ? prefix + "…" : prefix;
}

export function projectLiveActivities(source: LiveActivitiesSource): LiveActivitiesProjection {
  const all: LiveActivityRow[] = [];
  // A parked human question outranks everything: it is the only row the
  // user has to act on, and the turn keeps running regardless.
  for (const question of source.userQuestions ?? []) {
    const preview = questionPreview(question.text);
    const head = question.short_id.length > 0 ? question.short_id : question.id;
    all.push({
      key: `user-question:${question.id}`,
      role: "user-question",
      label: `? ${head} asks you · ${preview ? `"${preview}"` : "waiting for an answer"}`,
    });
  }
  // Questions have priority regardless of whether the child is a foreground
  // or background agent. Do not duplicate its normal running line.
  const questions = source.records.filter((record) => record.question !== undefined && record.status === "running");
  for (const record of questions) {
    const preview = questionPreview(record.question!.text);
    all.push({
      key: `question:${record.child_session}:${record.question!.id}`,
      role: "question",
      label: `? subagent(${record.display_name}) asks main · ${preview ? `"${preview}"` : "waiting for reply"}`,
    });
  }
  for (const record of source.records) {
    if (record.background !== true || record.task_id === undefined || record.question !== undefined) continue;
    all.push({
      key: `agent:${record.child_session}`,
      role: "agent",
      label: `⚡ subagent(${record.display_name}) · ${record.kind} ${formatSubagentElapsed(record.started_at, source.now)} · ${subagentPhase(record)}`,
    });
  }
  if (source.resultsWaiting > 0) {
    all.push({
      key: "background-results",
      role: "waiting",
      label: `⧗ ${source.resultsWaiting} background result${source.resultsWaiting === 1 ? "" : "s"} pending delivery`,
    });
  }
  for (const ticket of source.wakeups) {
    const tag = questionPreview(ticket.tag);
    all.push({
      key: `wakeup:${ticket.ticket_id}`,
      role: "wakeup",
      label: `◌ wakeup ${tag} · running (environment)`,
    });
  }
  if (source.activeDecisions > 0) {
    all.push({
      key: "decision",
      role: "coordination",
      label: `↔ ${source.activeDecisions} agent coordination call${source.activeDecisions === 1 ? "" : "s"} running`,
    });
  }
  const remaining = source.height === undefined ? MAX_VISIBLE_ROWS :
    Math.max(1, source.height - (source.bottomReserve ?? 0));
  const countOnly = remaining < 3;
  const budget = countOnly ? 1 : Math.min(MAX_VISIBLE_ROWS, remaining);
  const shown = all.slice(0, all.length > budget ? Math.max(0, budget - 1) : budget);
  return {
    rows: shown,
    hidden: Math.max(0, all.length - shown.length),
    total: all.length,
    countOnly,
  };
}

export const defaultActivityStyle: LiveActivityStyle = (role, text) => {
  switch (role) {
    case "question":
    case "user-question": return theme.warning(text);
    case "agent": return theme.accent(text);
    case "wakeup": return theme.info(text);
    case "coordination": return theme.info(text);
    case "waiting": return theme.success(text);
    default: return theme.muted(text);
  }
};

export function renderLiveActivities(
  projection: LiveActivitiesProjection, width: number,
  style: LiveActivityStyle = defaultActivityStyle,
): string[] {
  if (width <= 0 || projection.total === 0) return [];
  const fit = (value: string) => truncateToWidth(value, width, "");
  if (width < MIN_DETAILS_WIDTH || projection.countOnly) {
    return [style("muted", fit(`⚡ ${projection.total} live activit${projection.total === 1 ? "y" : "ies"}`))];
  }
  const lines = projection.rows.map((row) => style(row.role, fit(row.label)));
  if (projection.hidden > 0) lines.push(style("muted", fit(`+ ${projection.hidden} more activities`)));
  return lines;
}

export class LiveActivitiesHeader implements Component {
  constructor(
    private readonly source: () => LiveActivitiesSource,
    private readonly style: LiveActivityStyle = defaultActivityStyle,
  ) {}
  render(width: number): string[] {
    return renderLiveActivities(projectLiveActivities(this.source()), width, this.style);
  }
  invalidate(): void {}
}
