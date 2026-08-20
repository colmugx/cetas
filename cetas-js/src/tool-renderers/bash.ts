/**
 * bash.ts — `bash` tool renderer.
 *
 * Call view:    `→ bash  $ <command>`  with elapsed-seconds refresh via
 *               `setInterval(() => ctx.invalidate(), 1000)` while the tool
 *               is still pending.
 * Result view:  `  ✓ <exit info>`  +  first stdout/stderr line (truncated).
 *
 * The schema is `ext-bash`: { cmd: string } — `command` is read only as a
 * legacy alias because `extract_command` accepts both keys.
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  toolTitle,
  truncateForPreview,
  type ToolRenderContext,
  type ToolRenderer,
  type ToolRenderResultOptions,
} from "./registry.ts";

interface BashRowState {
  startedAt?: number;
  /** Active interval handle so we stop refreshing after completion. */
  timer?: ReturnType<typeof setInterval>;
}

function getState(ctx: ToolRenderContext): BashRowState {
  if (!ctx.state.bash) ctx.state.bash = {} as BashRowState;
  return ctx.state.bash as BashRowState;
}

/** Stop the elapsed-time timer once the row has a result. */
function stopTimer(ctx: ToolRenderContext) {
  const st = getState(ctx);
  if (st.timer) {
    clearInterval(st.timer);
    st.timer = undefined;
  }
}

export const bashRenderer: ToolRenderer = {
  renderCall(ctx: ToolRenderContext) {
    const cmd = argString(ctx.args, "cmd") ||
      argString(ctx.args, "command") ||
      "(empty)";
    const st = getState(ctx);
    if (st.startedAt === undefined) {
      st.startedAt = Date.now();
      // Tick once per second while the tool runs. pi-tui dedups identical
      // renders, so invalidating is cheap even if nothing visibly changes.
      st.timer = setInterval(() => {
        // Tool finished between ticks → stop.
        if (st.timer === undefined) return;
        ctx.invalidate();
      }, 1000);
    }
    const elapsed = Math.max(0, Math.floor((Date.now() - st.startedAt) / 1000));
    return new Text(
      `${theme.accent("→")} ${toolTitle("bash")} ${theme.muted("$")} ${cmd}  ` +
        theme.dim(`${elapsed}s`),
      1,
      0,
    );
  },
  renderResult(
    result,
    _opts: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    stopTimer(ctx);
    const cmd = argString(ctx.args, "cmd") || argString(ctx.args, "command");
    const status = result.isError ? theme.error("✗") : theme.success("✓");
    const first = truncateForPreview(result.content.split("\n")[0] ?? "", 200);
    return new Text(
      `  ${status} ${toolTitle("bash")} ${theme.muted("$")} ${cmd}` +
        (first ? `\n      ${theme.muted(first)}` : ""),
      1,
      0,
    );
  },
};
