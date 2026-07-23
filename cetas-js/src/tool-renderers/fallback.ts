/**
 * fallback.ts — generic tool renderer used when no specific renderer is
 * registered. Shows the tool name, args as JSON, and (on completion) the
 * truncated result.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  type ToolRenderContext,
  type ToolRenderResultOptions,
  type ToolRenderer,
  toolTitle,
  truncateForPreview,
} from "./registry.ts";

export const fallbackRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const argsJson = JSON.stringify(ctx.args ?? {});
    return new Text(
      `${toolTitle("(tool)")} ${theme.muted(argsJson)}`,
      1,
      0,
    );
  },
  renderResult(
    result,
    _options: ToolRenderResultOptions,
    _ctx: ToolRenderContext,
  ) {
    const status = result.isError ? theme.error("✗") : theme.success("✓");
    const body = truncateForPreview(result.content);
    return new Text(
      `  ${status} ${body}`,
      1,
      0,
    );
  },
};

// Re-export so host can `import { fallbackRenderer } from "./fallback"`.
export { theme };
