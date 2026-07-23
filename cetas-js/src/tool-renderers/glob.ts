/**
 * glob.ts — `glob` tool renderer.
 *
 * Call view:    `→ glob <pattern>  <path?>`
 * Result view:  `  ✓ N files`  with first 3 paths inline.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  toolTitle,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";

export const globRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const pattern = argString(ctx.args, "pattern") || "(no pattern)";
    const path = argString(ctx.args, "path") || ".";
    return new Text(
      `${theme.accent("→")} ${toolTitle("glob")} ${theme.yellow(pattern)}  ${theme.muted(path)}`,
      1,
      0,
    );
  },
  renderResult(result, _opts, _ctx) {
    const status = result.isError ? theme.error("✗") : theme.success("✓");
    if (result.isError) {
      return new Text(`  ${status} ${result.content.slice(0, 200)}`, 1, 0);
    }
    const files = result.content.split("\n").filter((l) => l.length > 0);
    const head = files.slice(0, 3).map((p) => theme.muted(p)).join("  ");
    const more = files.length > 3 ? theme.dim(` (+${files.length - 3} more)`) : "";
    return new Text(
      `  ${status} ${theme.muted(`${files.length} file${files.length === 1 ? "" : "s"}`)}` +
        (head ? `\n      ${head}${more}` : ""),
      1,
      0,
    );
  },
};
