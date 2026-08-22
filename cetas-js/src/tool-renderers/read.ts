/**
 * read.ts — `read` tool renderer.
 *
 * Call view:    `● read  <path>`
 * Result view:  `● <first line> … (+N lines)` (red ● for error)
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  type ToolRenderContext,
  type ToolRenderer,
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  truncateForPreview,
} from "./registry.ts";

export const readRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const path = argString(ctx.args, "path") || "(no path)";
    return new Text(`${callBullet(ctx)} ${toolTitle("read")}  ${path}`, 1, 0);
  },
  renderResult(result, _opts, ctx) {
    const path = argString(ctx.args, "path") || "";
    const lines = result.content.split("\n");
    const lineCount = lines.length;
    const firstLine = truncateForPreview(lines[0] ?? "", 120);
    const summary = result.isError
      ? truncateForPreview(result.content, 200)
      : lineCount > 1
      ? `${firstLine}  ${theme.muted(`(+${lineCount - 1} lines)`)}`.trim()
      : firstLine;
    return new Text(
      `${statusBullet(result.isError ? "error" : "success")} ${toolTitle("read")}  ${path}${summary ? "\n      " + theme.muted(summary) : ""}`,
      1,
      0,
    );
  },
};
