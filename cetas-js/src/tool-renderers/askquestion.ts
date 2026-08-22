/**
 * askquestion.ts — `ask_question` tool renderer.
 *
 * Call view:    `● ask <question>` plus the option list for select prompts
 *               (or a type hint for input/confirm).
 * Result view:  `● ask <question>` with the answer below — the question
 *               must outlive its answer
 *
 * The question dialog itself is rendered by the extension-UI overlay; this
 * row is the transcript record, so it leads with the question text — never
 * the raw arguments object.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";

function argStringList(args: unknown, key: string): string[] {
  const value = (args as Record<string, unknown> | null)?.[key];
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}

export const askQuestionRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const question = argString(ctx.args, "question") || "(no question)";
    const options = argStringList(ctx.args, "options");
    const type = argString(ctx.args, "type") || (options.length > 0 ? "select" : "input");
    const head = `${callBullet(ctx)} ${toolTitle("ask")} ${question}`;
    if (options.length > 0) {
      const list = options.map((o) => theme.muted(`「${o}」`)).join(" ");
      return new Text(`${head}\n      ${theme.dim(`[${type}]`)} ${list}`, 1, 0);
    }
    return new Text(`${head}  ${theme.dim(`[${type}]`)}`, 1, 0);
  },
  renderResult(result, _opts, ctx) {
    const question = argString(ctx.args, "question") || "(no question)";
    const bullet = statusBullet(result.isError ? "error" : "success");
    const answer = theme.muted(result.content.slice(0, 200));
    return new Text(`${bullet} ${toolTitle("ask")} ${question}\n      ${answer}`, 1, 0);
  },
};
