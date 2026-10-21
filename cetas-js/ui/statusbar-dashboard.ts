/**
 * Cetas-owned adaptive statusbar presentation.
 *
 * The extension supplies semantic fields; this module owns placement, width
 * and hierarchy. No config, color theme or second source of provider metrics.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import chalk from "chalk";
import { roleStyle, theme } from "./theme.ts";

/** Format the Core's current context reading without treating missing data as zero. */
export function contextOccupancy(raw: unknown): string | undefined {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return undefined;
  const state = raw as Record<string, unknown>;
  const tokens = (value: unknown): number | undefined =>
    typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
  const format = (value: number): string =>
    value >= 1_000_000 ? `${(Math.round(value / 100_000) / 10).toFixed(1)}M`
      : value >= 1_000 ? `${(Math.round(value / 100) / 10).toFixed(1)}K` : String(value);
  const window = tokens(state.window_tokens);
  const measured = tokens(state.last_measured_tokens);
  const estimate = tokens(state.estimated_added_tokens);
  const source = state.source;
  if (source !== "measured" && source !== "estimated" && source !== "unknown") return undefined;
  const used = source === "unknown" || measured === undefined || estimate === undefined
    ? undefined : measured + estimate;
  const occupancy = used === undefined ? "?" :
    `${source === "estimated" || estimate! > 0 ? "~" : ""}${format(used)}`;
  if (window === undefined || window === 0) return occupancy === "?" ? "?" : occupancy;
  return `${occupancy}/${format(window)}` +
    (used === undefined ? "" : ` · ${Math.floor(used * 100 / window)}%`);
}

export interface StatusbarEntry {
  readonly key: string;
  readonly value: string;
  readonly color?: string;
}
export interface StatusbarDashboardContext {
  readonly branch?: string;
  readonly contextValue?: string;
  readonly manager?: "Posoco" | "Magpie";
  readonly status?: string;
  readonly activeAgents?: number;
  readonly awaitingReplies?: number;
  /**
   * Non-blocking questions the human still owes an answer to. Never folded
   * into `status`: an unanswered question must not read as "waiting", or it
   * looks like the turn is blocked when it is not.
   */
  readonly pendingUserQuestions?: number;
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
 * Statusbar contract:
 * primary = selected provider/model:effort · manager · git branch · context.
 * Context follows the left-aligned header (or wraps when needed); the
 * permission mode leads the secondary rows unlabeled, the provider quota
 * windows follow as one group, and the remaining fields keep their
 * reported order (the registry pre-sorts by priority). Never invent
 * connectivity or reset state. Unknown extension metrics remain
 * available in the wrapped secondary rows, with an overflow indicator.
 */
export function renderStatusbarDashboard(
  entries: readonly StatusbarEntry[], width: number,
  context: StatusbarDashboardContext = {},
): string[] {
  if (width <= 0) return [];
  const get = (name: string) => entries.find(e => e.key.toLowerCase() === name);
  const model = get("model");
  const modelSlot = get("model_slot");
  const ctx = get("ctx");
  // The "model" segment is opaque (model name + effort), not a key/value
  // label: "model:high" is itself a valid model/effort pair. For the built-in
  // router, the independent model_slot segment supplies the actual provider
  // identity. Replace only the model-name part; ext-llm stays authoritative
  // for effort and its color. Never infer a provider from a model's name.
  const rawModel = model ? clean(model.value) : "";
  const slot = modelSlot ? clean(modelSlot.value) : "";
  const effortSeparator = rawModel.lastIndexOf(":");
  const displayModel = slot
    ? slot + (effortSeparator >= 0 ? rawModel.slice(effortSeparator) : "")
    : rawModel;
  const modelValue = displayModel
    ? (model?.color !== undefined
      ? roleStyle(model.color)(displayModel)
      : theme.bold(displayModel))
    : theme.muted("No model");
  // The active manager publishes its own neutral status segment. UI has
  // no knowledge of implementation choices or settings.json.
  const managerEntry = get("manager");
  const manager = managerEntry ? segment(managerEntry, false) : "";
  const branch = context.branch ? clean(context.branch) : "";
  const branchLabel = branch
    ? theme.muted("⑂ ") + chalk.hex("#9BE1A1")(branch)
    : "";
  const sep = theme.muted(" · ");
  const header = " " + modelValue + (manager ? sep + manager : "") +
    (branchLabel ? " " + branchLabel : "");
  const contextValue = ctx ? segment(ctx, false) : context.contextValue ?? "";
  const withContext = contextValue ? header + sep + contextValue : header;
  const postponeCtx = Boolean(contextValue) && visibleWidth(withContext) > width;
  const first = truncateToWidth(postponeCtx ? header : withContext, width, "…");

  const remaining = entries.filter(e => e !== model && e !== modelSlot && e !== ctx &&
    !["manager","router","status"].includes(e.key.toLowerCase()));
  const permission = remaining.find(e => e.key.toLowerCase() === "permission");
  const rest = remaining.filter(e => e !== permission);
  const isQuota = (e: StatusbarEntry) =>
    /^(5h|7d|weekly|monthly|quota|time_limit|remaining|usage)$/i.test(e.key);
  const format = (e: StatusbarEntry): string =>
    /reset/i.test(e.key) ? theme.warning("Reset ") + segment(e, false)
      : segment(e);
  const quota = rest.filter(isQuota).map(format);
  const others = rest.filter(e => !isQuota(e)).map(format);
  const activity = context.activeAgents || context.awaitingReplies
    ? `${context.activeAgents ?? 0} agent${context.activeAgents === 1 ? "" : "s"}` +
      (context.awaitingReplies ? ` · ${context.awaitingReplies} awaiting reply` : "")
    : "";
  const detail = [
    ...(permission ? [segment(permission, false)] : []),
    ...(postponeCtx ? [contextValue] : []),
    ...quota,
    ...(activity ? [theme.muted(activity)] : []),
    ...(context.pendingUserQuestions
      ? [theme.warning(`? ${context.pendingUserQuestions} to answer`)]
      : []),
    ...others,
  ];
  if (!detail.length) return [first];
  const maxRows = width < 28 ? 6 : width < 70 ? 4 : 2;
  return [first, ...wrapFields(detail, width - 1, maxRows).map(line => " " + line)];
}

/** Read nearest Git HEAD without spawning git or walking the whole workspace. */
export function readWorkspaceGitBranch(cwd: string): string | undefined {
  try {
    let dir = resolve(cwd);
    for (let depth = 0; depth < 20; depth++) {
      const git = join(dir, ".git");
      if (existsSync(git)) {
        const gitDir = statSync(git).isDirectory() ? git : (() => {
          const content = readFileSync(git, "utf8").trim();
          if (!content.startsWith("gitdir: ")) throw new Error("invalid git worktree pointer");
          const target = content.slice(8);
          return isAbsolute(target) ? target : resolve(dir, target);
        })();
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
