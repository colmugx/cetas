/**
 * write.ts — `write` tool renderer.
 *
 * Call view:    `● write <path>  (N bytes)`
 * Result view:  `● wrote <path>`
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

export const writeRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const path = argString(ctx.args, "path") || "(no path)";
    const content = argString(ctx.args, "content") ?? "";
    const bytes = content.length;
    return new Text(
      `${callBullet(ctx)} ${toolTitle("write")} ${path}  ${theme.muted(`(${bytes} bytes)`)}`,
      1,
      0,
    );
  },
  renderResult(result, _opts, ctx) {
    const path = argString(ctx.args, "path") ?? "";
    const body = result.isError
      ? truncateForPreview(result.content, 200)
      : `wrote ${path}`;
    return new Text(`${statusBullet(result.isError ? "error" : "success")} ${body}`, 1, 0);
  },
};
