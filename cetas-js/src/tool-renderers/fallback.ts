/**
 * fallback.ts — generic tool renderer used when no specific renderer is
 * registered. Shows the tool label, args as JSON, and (on completion) a
 * multi-line preview of the result — `structured.summary` when present.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  callBullet,
  EXPANDED_MAX,
  previewLines,
  statusBullet,
  type ToolRenderContext,
  type ToolRenderResultOptions,
  type ToolRenderer,
  toolTitle,
} from "./registry.ts";
import { summaryOf } from "./specs.ts";

export const fallbackRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const argsJson = JSON.stringify(ctx.args ?? {});
    return new Text(
      `${callBullet(ctx)} ${toolTitle(ctx.toolLabel)} ${theme.muted(argsJson)}`,
      1,
      0,
    );
  },
  renderResult(
    result,
    options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    const line1 = `${statusBullet(result.isError ? "error" : "success")} ${toolTitle(ctx.toolLabel)}`;
    const body =
      summaryOf(result.structured) ??
      previewLines(result.content, options.expanded ? EXPANDED_MAX : 3);
    if (!body) return new Text(line1, 1, 0);
    return new Text(`${line1}\n${body}`, 1, 0);
  },
};

// Re-export so host can `import { fallbackRenderer } from "./fallback"`.
export { theme };
