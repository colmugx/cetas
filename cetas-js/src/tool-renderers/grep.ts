/**
 * grep.ts — `grep` tool renderer.
 *
 * Call view:    `● grep <pattern>  <path?>`
 * Result view:  `● N matches`  or  `● no matches`
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  truncateForPreview,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";

export const grepRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const pattern = argString(ctx.args, "pattern") || "(no pattern)";
    const path = argString(ctx.args, "path") || ".";
    return new Text(
      `${callBullet(ctx)} ${toolTitle("grep")} ${theme.yellow(pattern)}  ${theme.muted(path)}`,
      1,
      0,
    );
  },
  renderResult(result, _opts, _ctx) {
    if (result.isError) {
      return new Text(`${statusBullet("error")} ${truncateForPreview(result.content, 200)}`, 1, 0);
    }
    const matchCount = result.content
      .split("\n")
      .filter((l) => l.length > 0).length;
    const summary = matchCount === 0
      ? "no matches"
      : `${matchCount} match${matchCount === 1 ? "" : "es"}`;
    return new Text(`${statusBullet("success")} ${theme.muted(summary)}`, 1, 0);
  },
};
