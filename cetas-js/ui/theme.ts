/**
 * theme.ts — fixed dark theme for cetas-js.
 *
 * MVP scope (per plan §"不在本规划内"): we do NOT hot-swap themes or read
 * OSC 11. The theme is a frozen record of (chalk style -> string -> string)
 * functions plus a couple of bg helpers for the Box component. Move to a
 * JSON/theme-loader if/when we add light mode.
 *
 * Slot names (toolTitle / toolOutput / accent / warning / error / muted)
 * follow pi-tui's Theme vocabulary so a future migration to its Theme type
 * is a 1:1 rename.
 */

import chalk from "chalk";

export type StyleFn = (text: string) => string;

export interface CetasTheme {
  // Identity / branding.
  brand: StyleFn;
  brandBold: StyleFn;
  // Role-based message styles.
  user: StyleFn;
  userBg: StyleFn;
  /** Full-width tinted background (#343541 dark) for the user-message Box. */
  userMessageBg: StyleFn;
  assistant: StyleFn;
  thinking: StyleFn;
  // Status colors.
  accent: StyleFn;
  warning: StyleFn;
  error: StyleFn;
  success: StyleFn;
  info: StyleFn;
  muted: StyleFn;
  yellow: StyleFn;
  red: StyleFn;
  // Tool rendering.
  toolTitle: StyleFn;
  toolArgs: StyleFn;
  toolOutput: StyleFn;
  toolPendingBg: StyleFn;
  toolErrorBg: StyleFn;
  toolSuccessBg: StyleFn;
  /** Selected row of an inline ask list — full-width background block. */
  selection: StyleFn;
  // Typography helpers.
  bold: StyleFn;
  italic: StyleFn;
  underline: StyleFn;
  dim: StyleFn;
}

export const theme: CetasTheme = {
  brand: chalk.cyan,
  brandBold: chalk.bold.cyan,
  user: chalk.white,
  userBg: chalk.bgCyan,
  // User-message tint (#343541 dark) — subtle so the Box reads as
  // a distinct zone without overwhelming the assistant text below it.
  userMessageBg: chalk.bgHex("#343541"),
  assistant: chalk.gray,
  thinking: chalk.italic.gray,
  accent: chalk.cyan,
  warning: chalk.yellow,
  error: chalk.red,
  success: chalk.green,
  info: chalk.blue,
  muted: chalk.gray,
  yellow: chalk.yellow,
  red: chalk.red,
  toolTitle: chalk.bold.yellow,
  toolArgs: chalk.gray,
  toolOutput: chalk.white,
  // Backgrounds — keep subtle so ANSI looks fine on both true-color and
  // 256-color terminals. chalk.bgRgb needs true-color; use named variants
  // for portability.
  toolPendingBg: chalk.bgHex("#333322"),
  toolErrorBg: chalk.bgHex("#3a1414"),
  toolSuccessBg: chalk.bgHex("#103a10"),
  /** Selected row of an inline ask list — a full-width background block
   * instead of an arrow prefix. */
  selection: chalk.bold.bgCyan.black,
  bold: chalk.bold,
  italic: chalk.italic,
  underline: chalk.underline,
  dim: chalk.dim,
};

/** Markdown theme — pi-tui Markdown component consumes this shape. */
import type { MarkdownTheme } from "@earendil-works/pi-tui";

export const markdownTheme: MarkdownTheme = {
  heading: chalk.bold.cyan,
  link: chalk.cyan,
  linkUrl: chalk.gray,
  code: chalk.yellow,
  codeBlock: (s) => chalk.gray(s),
  codeBlockBorder: chalk.gray,
  quote: chalk.italic.gray,
  quoteBorder: chalk.gray,
  hr: chalk.gray,
  listBullet: chalk.cyan,
  bold: chalk.bold,
  italic: chalk.italic,
  strikethrough: chalk.strikethrough,
  underline: chalk.underline,
};
