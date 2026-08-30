/**
 * write.ts — `write` tool renderer with a live streaming-args view.
 *
 * While the model streams a write call's arguments, the `content` arg
 * arrives fragment by fragment; this renderer shows it the way
 * ThinkingComponent shows streaming reasoning: a compact header plus the
 * last 3 tail lines of the partially-unescaped content. When the call
 * completes (`tool_call_started` carries the full authoritative args and
 * flips argsComplete), views delegate to `specRenderer(writeSpec)` so the
 * finalized look is byte-identical to the former declarative table entry.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  callBullet,
  toolTitle,
  specRenderer,
  type ToolRenderContext,
  type ToolRenderer,
} from "./registry.ts";
import { writeSpec } from "./specs.ts";

const TAIL_LINES = 3;

/** Finalized call + result views: exactly the old writeSpec output. */
const spec = specRenderer(writeSpec);

/** Last N physical lines of a (possibly still-growing) string. */
function tailLines(s: string, n: number): string {
  return s.split("\n").slice(-n).join("\n");
}

/** Streaming view: `● write <path>  · N lines` + dim tail of content. */
function renderStreamingCall(ctx: ToolRenderContext) {
  const path = argString(ctx.args, "path");
  const content = argString(ctx.args, "content");
  let head = `${callBullet(ctx)} ${toolTitle("write")}`;
  head += path.length > 0 ? ` ${path}` : " …";
  if (content.length > 0) {
    const lineCount = content.split("\n").length;
    head += `  ${theme.muted(`· ${lineCount} lines`)}`;
    return new Text(
      `${head}\n      ${theme.thinking(tailLines(content, TAIL_LINES))}`,
      1,
      0,
    );
  }
  return new Text(head, 1, 0);
}

export const writeRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    if (!ctx.argsComplete) return renderStreamingCall(ctx);
    return spec.renderCall?.(ctx) ?? renderStreamingCall(ctx);
  },
  renderResult(result, options, ctx) {
    return (
      spec.renderResult?.(result, options, ctx) ??
      new Text(result.content.slice(0, 200), 1, 0)
    );
  },
};
