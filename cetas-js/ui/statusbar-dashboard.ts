/**
 * Cetas-owned adaptive statusbar presentation.
 *
 * The extension supplies semantic fields; this module owns placement, width
 * and hierarchy. No config, color theme or second source of provider metrics.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { roleStyle, theme } from "./theme.ts";

export interface StatusbarEntry {
  readonly key: string;
  readonly value: string;
  readonly color?: string;
}
export interface StatusbarDashboardContext {
  readonly branch?: string;
  readonly status?: string;
  readonly activeAgents?: number;
  readonly awaitingReplies?: number;
}

function clean(text: string): string {
  return text.replace(/[\x00-\x1f\x7f-\x9f]/g, " ").replace(/\s+/g, " ").trim();
}
function valueOf(entry: StatusbarEntry): string {
  const raw = clean(entry.value);
  const prefix = `${entry.key}:`;
  return raw.startsWith(prefix) ? raw.slice(prefix.length).trimStart() : raw;
}
function segment(entry: StatusbarEntry, label = true, primary = false): string {
  const raw = valueOf(entry);
  const value = entry.color !== undefined ? roleStyle(entry.color)(raw)
    : primary ? theme.bold(raw) : raw;
  return label ? theme.muted(`${clean(entry.key)} `) + value : value;
}
function putRow(left: string, right: string, width: number): string {
  if (!right) return truncateToWidth(left, width, "…");
  const rest = width - visibleWidth(left) - visibleWidth(right);
  if (rest >= 2) return left + " ".repeat(rest) + right;
  return truncateToWidth(left, width, "…");
}

/** Keep field boundaries intact. A narrow window wraps whole fields. */
function wrapFields(fields: readonly string[], width: number, maxRows: number): string[] {
  if (width <= 0 || maxRows <= 0 || fields.length === 0) return [];
  const delimiter = theme.muted(" · ");
  const lines: string[] = [];
  let current = "";
  let used = 0;
  for (const field of fields) {
    if (lines.length >= maxRows) break;
    const part = truncateToWidth(field, width - (width > 8 ? 1 : 0), "…");
    const next = current.length === 0 ? part : current + delimiter + part;
    if (current.length > 0 && visibleWidth(next) > width) {
      lines.push(current);
      current = part;
      if (lines.length >= maxRows) break;
    } else {
      current = next;
    }
    used++;
  }
  if (lines.length < maxRows && current !== "") lines.push(current);
  if (used < fields.length && lines.length > 0) {
    // Never silently hide extra metrics: /statusbar exposes all values.
    const notice = theme.muted(`+${fields.length - used} more · /statusbar`);
    const last = lines.length - 1;
    if (visibleWidth(lines[last] + delimiter + notice) <= width)
      lines[last] += delimiter + notice;
    else
      lines[last] = truncateToWidth(notice, width, "…");
  }
  return lines;
}

/**
 * Row 1: brand · model · branch, with context aligned right when possible.
 * Row 2+: live status, agent summary, and provider metrics wrapped by field.
 */
export function renderStatusbarDashboard(
  entries: readonly StatusbarEntry[], width: number,
  context: StatusbarDashboardContext = {},
): string[] {
  if (width <= 0 || entries.length === 0) return [];
  const get = (name: string) => entries.find((e) => e.key.toLowerCase() === name);
  const model = get("model");
  const ctx = get("ctx");
  const brand = theme.bold("cetas");
  const sep = theme.muted(" │ ");
  const head = [brand, model ? segment(model, false, true) : undefined,
    context.branch ? theme.muted("⑂ ") + clean(context.branch) : undefined]
    .filter((v): v is string => v !== undefined).join(sep);
  const contextValue = ctx ? segment(ctx, true) : "";
  const leading = " " + head;
  let first: string;
  let postponeCtx = false;
  if (contextValue && width >= 50 &&
      visibleWidth(leading) + visibleWidth(contextValue) + 2 <= width) {
    first = putRow(leading, contextValue, width);
  } else {
    first = truncateToWidth(leading, width, "…");
    postponeCtx = Boolean(contextValue);
  }
  const status = clean(context.status ?? "Ready");
  const activity = context.activeAgents || context.awaitingReplies
    ? `${context.activeAgents ?? 0} agent${context.activeAgents === 1 ? "" : "s"}` +
      (context.awaitingReplies ? ` · ${context.awaitingReplies} awaiting reply` : "")
    : "";
  const misc = entries.filter((e) => e !== model && e !== ctx).map((e) => segment(e));
  const fields = [theme.accent(status), ...(activity ? [theme.muted(activity)] : []),
    ...(postponeCtx ? [contextValue] : []), ...misc];
  const rowBudget = width < 28 ? 6 : width < 70 ? 5 : 4;
  return [first, ...wrapFields(fields, width - 1, rowBudget).map((r) => " " + r)];
}

/** Read nearest Git HEAD without spawning git or walking the whole workspace. */
export function readWorkspaceGitBranch(cwd: string): string | undefined {
  try {
    let dir = resolve(cwd);
    for (let depth = 0; depth < 20; depth++) {
      const git = join(dir, ".git");
      if (existsSync(git)) {
        const content = readFileSync(git, "utf8").trim();
        const gitDir = content.startsWith("gitdir: ")
          ? (isAbsolute(content.slice(8)) ? content.slice(8) : resolve(dir, content.slice(8)))
          : git;
        const head = readFileSync(join(gitDir, "HEAD"), "utf8").trim();
        return head.startsWith("ref: refs/heads/") ? clean(head.slice(16)) :
          /^[0-9a-f]{40,64}$/i.test(head) ? head.slice(0, 8) : undefined;
      }
      const next = dirname(dir);
      if (next === dir) break;
      dir = next;
    }
  } catch { /* Not a git repo, unreadable worktree or no HEAD. */ }
  return undefined;
}
