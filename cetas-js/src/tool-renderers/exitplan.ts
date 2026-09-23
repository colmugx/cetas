/**
 * exitplan.ts — `exit_plan_mode` tool renderer.
 *
 * Call view:    `● plan <name>` plus the full plan body rendered as
 *               markdown — the user must be able to read the plan they are
 *               about to approve, so no preview cap here (overflow scrolls
 *               into the terminal scrollback).
 * Result view:  `● plan <name>` with the outcome's first line and the saved
 *               plan-file path; the body already lives in the call view
 *               above, so it is never dumped twice.
 */

import { Container, Markdown, Text } from "@earendil-works/pi-tui";
import { markdownTheme, theme } from "../../ui/theme.ts";
import {
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  truncateForPreview,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";

const SAVED_PATH = /Saved to (.+)\.$/;

function planName(ctx: ToolRenderContext): string {
  return argString(ctx.args, "name") || "(unnamed)";
}

function headLine(ctx: ToolRenderContext, bullet: string): string {
  return `${bullet} ${toolTitle("plan")} ${planName(ctx)}`;
}

export const exitPlanRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const head = headLine(ctx, callBullet(ctx));
    const plan = argString(ctx.args, "plan");
    if (plan.length === 0) {
      return new Text(head, 1, 0);
    }
    const block = new Container();
    block.addChild(new Text(head, 1, 0));
    block.addChild(new Markdown(plan, 1, 0, markdownTheme));
    return block;
  },
  renderResult(result, _options, ctx) {
    const head = headLine(ctx, statusBullet(result.isError ? "error" : "success"));
    const firstLine = (result.content.split("\n")[0] ?? "").trim();
    const saved = SAVED_PATH.exec(result.content.trim())?.[1];
    const details: string[] = [];
    if (firstLine.length > 0) {
      details.push(theme.muted(truncateForPreview(firstLine, 160)));
    }
    if (saved !== undefined) {
      details.push(theme.muted(saved));
    }
    if (details.length === 0) {
      return new Text(head, 1, 0);
    }
    // Expanded (ctrl+o) intentionally changes nothing here: the full plan
    // already renders in the call view; expanding would only duplicate it.
    return new Text(`${head}\n      ${details.join("\n      ")}`, 1, 0);
  },
};
