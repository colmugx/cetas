/**
 * answer.ts — `answer_question` tool renderer: the parent agent's reply to
 * a parked subagent question.
 *
 * Call view:   `● answer · question-1`
 * Result view: `● answer → apple` + the question→answer pair — taken from
 *              the receipt's structured payload when live, from the
 *              persisted content lines on replay (the session disk format
 *              has no structured payloads).
 *
 * This row is the durable transcript record of the answer; together with
 * the `agent` row's waiting card it gives the user the full ask→answer
 * round trip in the stream.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import { fallbackRenderer } from "./fallback.ts";
import {
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  type ToolRenderContext,
  type ToolRenderer,
  type ToolRenderResultOptions,
  type ToolRenderResultPayload,
} from "./registry.ts";

export const answerQuestionRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const questionId = argString(ctx.args, "question_id") || "(no question id)";
    return new Text(
      `${callBullet(ctx)} ${toolTitle("answer")} ${theme.dim(`· ${questionId}`)}`,
      1,
      0,
    );
  },
  renderResult(
    result: ToolRenderResultPayload,
    options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    if (!result.isError) {
      const answered =
        answeredFromStructured(result.structured, ctx.args) ??
        answeredFromContent(result.content);
      if (answered !== undefined) {
        return new Text(answeredView(answered, ctx), 1, 0);
      }
    }
    const render = fallbackRenderer.renderResult;
    if (render === undefined) {
      return new Text(`  ${result.content.slice(0, 200)}`, 1, 0);
    }
    return render(result, options, ctx);
  },
};

/** One submitted answer: who was asked, what was asked, what was replied. */
interface Answered {
  readonly childSession: string;
  readonly question: string;
  readonly answer: string;
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

function oneLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** The answer phrase the model submitted, rendered from the call args. */
function answerWord(
  args: Record<string, unknown>,
  type: "input" | "confirm" | "select",
  options: readonly string[],
): string {
  if (type === "confirm") {
    return args.confirm === true ? "true" : args.confirm === false ? "false" : "";
  }
  if (type === "select") {
    const raw = typeof args.index === "number" ? args.index : Number.NaN;
    const index = Number.isInteger(raw) ? raw : -1;
    if (index < 0) return "";
    const option = options[index];
    return `${option ?? `option ${index}`} (index ${index})`;
  }
  return typeof args.text === "string" ? oneLine(args.text) : "";
}

/** Live path: the receipt's structured payload + the call args. */
function answeredFromStructured(
  structured: unknown,
  args: unknown,
): Answered | undefined {
  if (
    structured === null ||
    typeof structured !== "object" ||
    Array.isArray(structured)
  ) {
    return undefined;
  }
  const s = structured as Record<string, unknown>;
  if (s.answered !== true) return undefined;
  const question = typeof s.question === "string" ? s.question : "";
  const type = normalizeType(typeof s.type === "string" ? s.type : undefined);
  const options = stringList(s.options);
  const answer =
    answerWord(
      (args ?? {}) as Record<string, unknown>,
      type,
      options,
    ) || oneLine(typeof s.answer === "string" ? s.answer : "");
  if (question.length === 0 && answer.length === 0) return undefined;
  return {
    childSession: typeof s.child_session === "string" ? s.child_session : "",
    question,
    answer,
  };
}

/** Replay path: the persisted receipt echoes `question:` / `answer:` lines. */
function answeredFromContent(content: string): Answered | undefined {
  let question = "";
  let answer = "";
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    const value = (prefix: string): string | undefined =>
      line.startsWith(prefix) ? line.slice(prefix.length).trim() : undefined;
    const q = value("question: ");
    if (q !== undefined) question = q;
    const a = value("answer: ");
    if (a !== undefined) answer = a;
  }
  if (question.length === 0 && answer.length === 0) return undefined;
  return { childSession: "", question, answer };
}

function answeredView(answered: Answered, ctx: ToolRenderContext): string {
  const named =
    (answered.childSession.length > 0
      ? ctx.subagentActivity?.get(answered.childSession)?.display_name
      : undefined) ??
    (answered.childSession.length > 0 ? answered.childSession : undefined);
  const head = `${statusBullet("success")} ${toolTitle("answer")}${
    named !== undefined ? ` → ${theme.muted(named)}` : ""
  }`;
  if (answered.question.length === 0) {
    return `${head}\n    ${theme.muted(answered.answer)}`;
  }
  return `${head}\n    "${answered.question}" → ${theme.muted(answered.answer)}`;
}
