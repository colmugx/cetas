/**
 * subagent.ts — `agent` tool renderer with live child-run progress.
 *
 * Call view:  `● agent · <kind> · <elapsed>s · step N · <current tool>`
 *             + a dim trailing window of the child's latest text.
 * Result view: delegates to the fallback renderer — the terminal footer
 *             (child_session + usage) already carries the summary.
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
