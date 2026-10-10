/** Product identity and setup guidance, projected only from safe UI snapshots. */
import {
  stripTerminalSequences,
  truncateToWidth,
  visibleWidth,
  type Component,
} from "@earendil-works/pi-tui";
import type { AppState } from "../src/app/types.ts";
import { theme } from "./theme.ts";

// A six-row terminal cut of the Wakeful mark, using half-block cells.
const WAKEFUL = [
  "▄██████████▄",
  "███▀▀███▀███",
  "███▄▄███▄███",
  "███████▀▀▀▀▀",
  "███████▄▄▄▄ ",
  "▀█████████▀ ",
] as const;

export interface WelcomeHeaderSource {
  cwd: string;
  home: string;
  state?: AppState;
  model?: string;
  rows?: number;
}

/** File names and provider labels must never introduce terminal controls. */
function singleLine(value: string): string {
  return stripTerminalSequences(value).replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim();
}

export function welcomeWorkspace(cwd: string, home: string): string {
  const path = singleLine(cwd);
  const root = singleLine(home).replace(/[\\/]+$/, "");
  if (!root) return path;
  if (path === root) return "~";
  // A boundary check avoids abbreviating a sibling such as /home/annette.
  if (path.startsWith(root + "/") || path.startsWith(root + "\\")) {
    return "~" + path.slice(root.length);
  }
  return path;
}

export function renderWelcomeHeader(
  source: WelcomeHeaderSource,
  width: number,
  compact = false,
): string[] {
  if (width <= 0) return [];
  const columns = Math.floor(width);
  const workspace = welcomeWorkspace(source.cwd, source.home);
  const model = singleLine(source.model ?? "") || "Not selected";
  const needsSetup = source.state === "needs_setup";
  const starting = source.state === undefined;
  const fit = (value: string, max = columns): string => truncateToWidth(value, max, "…");
  const title = theme.brandBold("cetas");

  // Tiny / short terminals and active conversations retain only useful context.
  if (compact || columns < 40 || (source.rows ?? 24) < 22) {
    const lines = [fit(` ${title} ${theme.muted("· " + workspace)}`)];
    if (!compact && needsSetup && columns >= 24) {
      lines.push(fit(" " + theme.muted("/login to connect a provider")));
    }
    return lines;
  }

  const cardWidth = Math.min(columns - 2, 88);
  const contentWidth = cardWidth - 4;
  const border = (left: string, right: string): string =>
    " " + theme.muted(left + "─".repeat(cardWidth - 2) + right);
  const row = (value: string): string => {
    const clipped = fit(value, contentWidth);
    return " " + theme.muted("│ ") + clipped +
      " ".repeat(contentWidth - visibleWidth(clipped)) + theme.muted(" │");
  };
  const context = [
    title,
    theme.muted("One agent. Every surface."),
    "",
    theme.muted("Model      ") + theme.bold(model),
    theme.muted("Workspace  ") + workspace,
    theme.muted("Built on Posoco"),
  ];
  const body = columns >= 64
    ? context.map((value, i) => row(theme.brand(WAKEFUL[i]) + "   " + value))
    : [context[0], context[1], context[3], context[4]].map(row);
  const narrow = columns < 64;
  const guidance = starting
    ? theme.muted("Starting your workspace…")
    : needsSetup
      ? theme.brand("/login") + theme.muted(narrow ? " connect  ·  " : " connect a provider  ·  ") + theme.brand("/model") + theme.muted(narrow ? " choose" : " choose a model")
      : theme.muted(narrow ? "Describe a task. " : "Describe a task to begin. ") + theme.brand("/help") + theme.muted(" for commands.");
  const shortcuts = needsSetup || starting
    ? theme.muted(narrow ? "Shared settings · ~/.cetas/" : "Your credentials and model choice are shared across Cetas.")
    : theme.brand("@path") + theme.muted(narrow ? " files  ·  " : " add a file  ·  ") + theme.brand("/sessions") + theme.muted(narrow ? " history" : " resume work");
  return ["", border("╭", "╮"), row(""), ...body, row(""),
    border("╰", "╯"), fit(" " + guidance), fit(" " + shortcuts), ""];
}

export class WelcomeHeader implements Component {
  compact = false;
  constructor(private readonly source: () => WelcomeHeaderSource) {}
  render(width: number): string[] {
    return renderWelcomeHeader(this.source(), width, this.compact);
  }
  invalidate(): void {}
}
