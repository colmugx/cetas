/**
 * Shared shell renderer for the `bash` and `powershell` tools.
 *
 * Bash:       `● Ran(bash) $ <command>`
 * PowerShell: `● Ran(ps1) PS> <command>`
 *
 * Both views keep the command after completion and preview stdout/stderr.
 * Each running row refreshes its elapsed-seconds counter once per second.
 * Both tools accept `cmd` (with `command` as a legacy alias).
 */

import { Text } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import {
  argString,
  callBullet,
  EXPANDED_MAX,
  previewLines,
  statusBullet,
  toolTitle,
  truncateForPreview,
  type ToolRenderContext,
  type ToolRenderer,
  type ToolRenderResultOptions,
} from "./registry.ts";

interface ShellRowState {
  startedAt?: number;
  /** Active interval handle so we stop refreshing after completion. */
  timer?: ReturnType<typeof setInterval>;
}

function getState(ctx: ToolRenderContext): ShellRowState {
  if (!ctx.state.shell) ctx.state.shell = {} as ShellRowState;
  return ctx.state.shell as ShellRowState;
}

/** The presentation name is intentionally independent of the extension label. */
function shellTitle(ctx: ToolRenderContext): string {
  return ctx.toolName === "powershell" ? "Ran(ps1)" : "Ran(bash)";
}

function shellPrompt(ctx: ToolRenderContext): string {
  return ctx.toolName === "powershell" ? "PS>" : "$";
}

/** Stop the elapsed-time timer once the row has a result. */
function stopTimer(ctx: ToolRenderContext) {
  const st = getState(ctx);
  if (st.timer) {
    clearInterval(st.timer);
    st.timer = undefined;
  }
}

export const shellRenderer: ToolRenderer = {
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
      `${callBullet(ctx)} ${toolTitle(shellTitle(ctx))} ${theme.muted(shellPrompt(ctx))} ${cmd}  ` +
        theme.dim(`${elapsed}s`),
      1,
      0,
    );
  },
  renderResult(
    result,
    options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ) {
    stopTimer(ctx);
    const cmd = argString(ctx.args, "cmd") || argString(ctx.args, "command");
    const body = options.expanded
      ? previewLines(result.content, EXPANDED_MAX)
      : truncateForPreview(result.content.split("\n")[0] ?? "", 200);
    return new Text(
      `${statusBullet(result.isError ? "error" : "success")} ${toolTitle(shellTitle(ctx))} ${theme.muted(shellPrompt(ctx))} ${cmd}` +
        (body ? `\n      ${theme.muted(body)}` : ""),
      1,
      0,
    );
  },
};
