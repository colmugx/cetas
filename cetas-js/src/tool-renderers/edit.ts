/**
 * edit.ts — `edit` tool renderer.
 *
 * ext-edit schema is old_text/new_text/replace_all (preserved per ADR Q4).
 * Call view:    `● edit  <path>  (replace_all? yes : single)`
 * Result view:  `● edited <path>`
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argBool,
  argString,
  callBullet,
  statusBullet,
  toolTitle,
  truncateForPreview,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";

export const editRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const path = argString(ctx.args, "path") || "(no path)";
    const replaceAll = argBool(ctx.args, "replace_all", false);
    const mode = replaceAll ? "all" : "single";
    return new Text(
      `${callBullet(ctx)} ${toolTitle("edit")}  ${path}  ${theme.muted(`(${mode})`)}`,
      1,
      0,
    );
  },
  renderResult(result, _opts, ctx) {
    const path = argString(ctx.args, "path") ?? "";
    const body = result.isError
      ? truncateForPreview(result.content, 200)
      : `edited ${path}`;
    return new Text(`${statusBullet(result.isError ? "error" : "success")} ${body}`, 1, 0);
  },
};
