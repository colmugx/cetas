/**
 * grep.ts — `grep` tool renderer.
 *
 * Call view:    `→ grep <pattern>  <path?>`
 * Result view:  `  ✓ N matches`  or  `  ✓ no matches`
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
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
      `${theme.accent("→")} ${toolTitle("grep")} ${theme.yellow(pattern)}  ${theme.muted(path)}`,
      1,
      0,
    );
  },
  renderResult(result, _opts, _ctx) {
    const status = result.isError ? theme.error("✗") : theme.success("✓");
    if (result.isError) {
      return new Text(`  ${status} ${truncateForPreview(result.content, 200)}`, 1, 0);
    }
    const matchCount = result.content
      .split("\n")
      .filter((l) => l.length > 0).length;
    const summary = matchCount === 0
      ? "no matches"
      : `${matchCount} match${matchCount === 1 ? "" : "es"}`;
    return new Text(`  ${status} ${theme.muted(summary)}`, 1, 0);
  },
};
