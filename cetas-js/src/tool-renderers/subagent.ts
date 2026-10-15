/**
 * subagent.ts — `agent` tool renderer with live child-run progress.
 *
 * Call view:  `● agent · <kind> · <elapsed>s · step N · <current tool>`
 *             + a dim trailing window of the child's latest text.
 * Result view: a `waiting_reply` receipt gets a dedicated question card —
 *             the durable transcript record of the child's ask; everything
 *             else delegates to the fallback renderer.
 *
 * Live data comes from the shell-owned SubagentActivityStore, reached via
 * ToolRowOptions → ctx.subagentActivity and keyed on the row's FINAL call
 * id (streaming adoption re-keys through ToolRow.setCallId). This module is
 * pure rendering: no module-level row registry, no ticker, no singleton.
 * Refreshing is driven by the event router (child events + the shell's 1s
 * tick) through ToolRow.refreshLive(), gated by the host's visibility check.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import { fallbackRenderer } from "./fallback.ts";
import {
  callBullet,
  statusBullet,
  toolTitle,
  type ToolRenderContext,
  type ToolRenderer,
  type ToolRenderResultOptions,
  type ToolRenderResultPayload,
} from "./registry.ts";

export const subagentRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const activity = ctx.subagentActivity?.runningForParentCall(ctx.toolCallId);
    const parts = [toolTitle("agent")];
    let tail = "";
    if (activity !== undefined) {
      parts.push(theme.muted(activity.kind));
      if (activity.model !== undefined) {
        const effortNote = activity.effort !== undefined ? `(${activity.effort})` : "";
        parts.push(theme.muted(`${activity.model}${effortNote}`));
      }
      const elapsed = Math.max(
        0,
        Math.floor((Date.now() - activity.started_at) / 1000),
      );
      parts.push(theme.dim(`${elapsed}s`));
      if (activity.steps > 0) parts.push(theme.dim(`step ${activity.steps}`));
      const tool = activity.current_tool ?? activity.last_tool;
      if (tool !== undefined) parts.push(theme.muted(`· ${tool}`));
      const trimmed = activity.text_tail.replace(/\s+/g, " ").trim();
      if (trimmed.length > 0) {
        tail = trimmed.length > 160 ? `…${trimmed.slice(-160)}` : trimmed;
      }
    }
    let text = `${callBullet(ctx)} ${parts.join(" ")}`;
    if (tail.length > 0) text += `\n  ${theme.dim(`⋮ ${tail}`)}`;
    if (ctx.expanded && activity !== undefined && activity.history.length > 0) {
      const lines = activity.history
        .slice(-8)
        .map((entry) => `  ${theme.dim(entry)}`)
        .join("\n");
      text += `\n${lines}`;
    }
    return new Text(text, 1, 0);
  },
  renderResult(
    result: ToolRenderResultPayload,
    options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    if (!result.isError) {
      const waiting =
        waitingFromStructured(result.structured) ??
        parseWaitingReceipt(result.content);
      if (waiting !== undefined) {
        return new Text(waitingView(waiting, options, ctx), 1, 0);
      }
    }
    const render = fallbackRenderer.renderResult;
    // The renderer interface allows an absent slot; ToolRow.rebuild requires
    // a Component, so degrade to the raw content line instead of undefined.
    if (render === undefined) {
      return new Text(`  ${result.content.slice(0, 200)}`, 1, 0);
    }
    // No try/catch: a renderer failure must surface, never be swallowed.
    return render(result, options, ctx);
  },
};

/** One child ask, as carried by the `waiting_reply` receipt. */
export interface WaitingReceipt {
  readonly questionId: string;
  readonly childSession: string;
  readonly kind: string;
  readonly question: string;
  readonly type: "input" | "confirm" | "select";
  /** Select options; empty for input/confirm. */
  readonly options: readonly string[];
}

function normalizeType(
  word: string | undefined,
): "input" | "confirm" | "select" {
  return word === "confirm" || word === "select" ? word : "input";
}

function stringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((v): v is string => typeof v === "string")
    : [];
}

/** Live path: the receipt's structured payload. */
function waitingFromStructured(
  structured: unknown,
): WaitingReceipt | undefined {
  if (
    structured === null ||
    typeof structured !== "object" ||
    Array.isArray(structured)
  ) {
    return undefined;
  }
  const s = structured as Record<string, unknown>;
  if (s.status !== "waiting_reply") return undefined;
  const questionId = typeof s.question_id === "string" ? s.question_id : "";
  const question = typeof s.question === "string" ? s.question : "";
  if (questionId.length === 0 && question.length === 0) return undefined;
  return {
    questionId,
    childSession: typeof s.child_session === "string" ? s.child_session : "",
    kind: typeof s.kind === "string" ? s.kind : "",
    question,
    type: normalizeType(typeof s.type === "string" ? s.type : undefined),
    options: stringList(s.options),
  };
}

/**
 * Replay path: the persisted receipt content (the session disk format has
 * no structured payloads). Lines are `key: value`; the question id lives
 * only in the trailing hint.
 */
export function parseWaitingReceipt(
  content: string,
): WaitingReceipt | undefined {
  let status = "";
  let childSession = "";
  let kind = "";
  let question = "";
  let type: "input" | "confirm" | "select" = "input";
  const options: string[] = [];
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    const value = (prefix: string): string | undefined =>
      line.startsWith(prefix) ? line.slice(prefix.length).trim() : undefined;
    const s = value("status: ");
    if (s !== undefined) status = s;
    const c = value("child_session: ");
    if (c !== undefined) childSession = c;
    const k = value("kind: ");
    if (k !== undefined) kind = k;
    const q = value("question: ");
    if (q !== undefined) question = q;
    const t = value("type: ");
    if (t !== undefined) type = normalizeType(t);
    const o = value("options: ");
    if (o !== undefined) {
      for (const item of o.split(" | ")) {
        const option = item.trim();
        if (option.length > 0) options.push(option);
      }
    }
  }
  if (status !== "waiting_reply" || question.length === 0) return undefined;
  const idMatch = content.match(/answer_question\(question_id="([^"]+)"\)/);
  return {
    questionId: idMatch?.[1] ?? "",
    childSession,
    kind,
    question,
    type,
    options,
  };
}

/** The question card: who asks, what, and how the parent model answers. */
function waitingView(
  waiting: WaitingReceipt,
  options: ToolRenderResultOptions,
  ctx: ToolRenderContext,
): string {
  const store = ctx.subagentActivity;
  const named =
    (waiting.childSession.length > 0
      ? store?.get(waiting.childSession)?.display_name
      : undefined) ??
    (waiting.kind.length > 0 ? waiting.kind : undefined) ??
    (waiting.childSession.length > 0 ? waiting.childSession : "subagent");
  const head = `${statusBullet("success")} ${toolTitle("agent")} → ${theme.muted(`${named} asks`)}${
    waiting.questionId.length > 0 ? theme.dim(` · ${waiting.questionId}`) : ""
  }`;
  const optionNote =
    waiting.options.length > 0
      ? ` ${waiting.options.map((o) => theme.muted(`「${o}」`)).join(" ")}`
      : "";
  let body = `    "${waiting.question}"  ${theme.dim(`[${waiting.type}]`)}${optionNote}`;
  if (options.expanded) {
    const meta = [
      waiting.childSession.length > 0
        ? `child_session: ${waiting.childSession}`
        : undefined,
      waiting.kind.length > 0 ? `kind: ${waiting.kind}` : undefined,
    ].filter((v) => v !== undefined);
    if (meta.length > 0) body += `\n    ${theme.dim(meta.join(" · "))}`;
  }
  if (waiting.questionId.length > 0) {
    body += `\n    ${theme.dim(`⤷ answer with answer_question(question_id="${waiting.questionId}")`)}`;
  }
  return `${head}\n${body}`;
}
