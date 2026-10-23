/**
 * notifyuser.ts — `notify_user` tool renderer (non-blocking ask).
 *
 * Call view:   `● asks <question>` plus the option list for select prompts
 *              (or a type hint for input/confirm).
 * Result view: `✓ asks <question>` with the short id plus the reply path —
 *              the question is still pending; the answer arrives through
 *              `/answer @qN` (reply box) or `/questions` (pick from all).
 *
 * This row is the durable transcript record: the live `? @qN asks you` line
 * above the editor disappears when the question is answered or expires,
 * while the transcript keeps the question and (through the user's own echo
 * message) the answer for replay.
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
  type ToolRenderResultOptions,
  type ToolRenderResultPayload,
} from "./registry.ts";

function argStringList(args: unknown, key: string): string[] {
  const value = (args as Record<string, unknown> | null)?.[key];
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}

/** The receipt echoes `short_id: @q3`; replay has no structured payload. */
function shortIdFromContent(content: string): string {
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("short_id: ")) return line.slice("short_id: ".length).trim();
  }
  return "";
}

export const notifyUserRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const question = argString(ctx.args, "question") || "(no question)";
    const options = argStringList(ctx.args, "options");
    const type = argString(ctx.args, "type") || (options.length > 0 ? "select" : "input");
    const head = `${callBullet(ctx)} ${toolTitle("asks")} ${question}`;
    if (options.length > 0) {
      const list = options.map((option) => theme.muted(`「${option}」`)).join(" ");
      return new Text(`${head}\n      ${theme.dim(`[${type}]`)} ${list}`, 1, 0);
    }
    return new Text(`${head}  ${theme.dim(`[${type}]`)}`, 1, 0);
  },
  renderResult(
    result: ToolRenderResultPayload,
    _options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    const question = argString(ctx.args, "question") || "(no question)";
    if (result.isError) {
      return new Text(
        `${statusBullet("error")} ${toolTitle("asks")} ${question}\n      ${theme.muted(result.content.slice(0, 200))}`,
        1,
        0,
      );
    }
    const structured = result.structured;
    const rawId =
      typeof structured === "object" && structured !== null
        ? (structured as Record<string, unknown>).short_id
        : undefined;
    const label =
      typeof rawId === "string" && rawId.length > 0 ? rawId : shortIdFromContent(result.content);
    const target = label.length > 0 ? ` /answer ${label}` : " /answer";
    return new Text(
      `${statusBullet("success")} ${toolTitle("asks")} ${question}\n      ${theme.muted(
        `${label.length > 0 ? `${label} ` : ""}submitted · awaiting your answer —${target} to reply · /questions lists all pending`,
      )}`,
      1,
      0,
    );
  },
};
