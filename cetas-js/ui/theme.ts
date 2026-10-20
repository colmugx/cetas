/**
 * Cetas terminal theme.
 *
 * OSC 10/11 supplies actual terminal foreground/background colors after the
 * TUI starts. Keep style functions stable so mounted Box/Markdown components
 * can pick up late replies without replacing the transcript. Never put
 * unknown/default terminal foreground text on a fixed dark background.
 */
import chalk from "chalk";
import type { MarkdownTheme, RgbColor, TerminalColors } from "@earendil-works/pi-tui";
import { contrastRatio, mixColor, relativeLuminance } from "./color-contrast.ts";

export type StyleFn = (text: string) => string;

export interface CetasTheme {
  brand: StyleFn;
  brandBold: StyleFn;
  user: StyleFn;
  userBg: StyleFn;
  userMessageBg: StyleFn;
  assistant: StyleFn;
  thinking: StyleFn;
  accent: StyleFn;
  warning: StyleFn;
  error: StyleFn;
  success: StyleFn;
  info: StyleFn;
  muted: StyleFn;
  yellow: StyleFn;
  red: StyleFn;
  toolTitle: StyleFn;
  toolArgs: StyleFn;
  toolOutput: StyleFn;
  toolPendingBg: StyleFn;
  toolErrorBg: StyleFn;
  toolSuccessBg: StyleFn;
  selection: StyleFn;
  bold: StyleFn;
  italic: StyleFn;
  underline: StyleFn;
  dim: StyleFn;
}

interface SurfaceColors {
  user?: RgbColor;
  toolPending?: RgbColor;
  toolError?: RgbColor;
  toolSuccess?: RgbColor;
}

const RGB = {
  pending: { r: 202, g: 156, b: 56 },
  error: { r: 212, g: 76, b: 76 },
  success: { r: 65, g: 173, b: 94 },
} as const;

/**
 * A subtle surface is safe only if the terminal's own foreground keeps a
 * 4.5:1 contrast ratio against it. If OSC 10 or OSC 11 is absent, transparent
 * is safer than guessing a dark/light theme.
 */
export function terminalSurfaceColors(colors: TerminalColors): SurfaceColors {
  const bg = colors.background;
  const fg = colors.foreground;
  if (!bg || !fg) return {};
  const surface = (tint: RgbColor, opacity: number): RgbColor | undefined => {
    const candidate = mixColor(bg, tint, opacity);
    return contrastRatio(fg, candidate) >= 4.5 ? candidate : undefined;
  };
  return {
    user: surface(fg, 0.11),
    toolPending: surface(RGB.pending, 0.12),
    toolError: surface(RGB.error, 0.12),
    toolSuccess: surface(RGB.success, 0.12),
  };
}

let terminalColors: TerminalColors = {};
let surfaces: SurfaceColors = {};

/** Called for OSC color results, including late or partial replies. */
export function configureTerminalTheme(colors: TerminalColors): void {
  terminalColors = {
    ...terminalColors,
    foreground: colors.foreground ?? terminalColors.foreground,
    background: colors.background ?? terminalColors.background,
  };
  surfaces = terminalSurfaceColors(terminalColors);
}

const identity: StyleFn = (text) => text;
const hexRgb = (hex: string): RgbColor => ({
  r: parseInt(hex.slice(1, 3), 16),
  g: parseInt(hex.slice(3, 5), 16),
  b: parseInt(hex.slice(5, 7), 16),
});

/** Keep semantic colors legible even on a nonstandard terminal background. */
const semantic = (darkBg: string, lightBg: string): StyleFn => (text) => {
  const bg = terminalColors.background;
  const variant = bg && relativeLuminance(bg) >= 0.179 ? lightBg : darkBg;
  const candidate = hexRgb(variant);
  const foreground = terminalColors.foreground;
  if (bg && foreground && contrastRatio(candidate, bg) < 4.5) {
    return chalk.rgb(foreground.r, foreground.g, foreground.b)(text);
  }
  return chalk.hex(variant)(text);
};

/** Dynamic wrappers: pi-tui Box constructors retain the function reference. */
const surfaceStyle = (kind: keyof SurfaceColors): StyleFn => (text) => {
  const bg = surfaces[kind];
  return bg ? chalk.bgRgb(bg.r, bg.g, bg.b)(text) : text;
};

const brand = semantic("#92CDB5", "#216B52");
const accent = semantic("#55CDE9", "#006780");
const warning = semantic("#FFD080", "#865700");
const error = semantic("#FF7E83", "#A7202A");
const success = semantic("#75D899", "#177039");
const info = semantic("#7FB0FF", "#234C9A");
const muted = semantic("#A0A0A0", "#565656");

export const theme: CetasTheme = {
  brand,
  brandBold: (s) => chalk.bold(brand(s)),
  // The terminal's own foreground is already the right contrast for its
  // default background and for the checked, subtly tinted message surface.
  user: identity,
  userBg: surfaceStyle("user"),
  userMessageBg: surfaceStyle("user"),
  assistant: identity,
  thinking: (s) => chalk.italic(muted(s)),
  accent,
  warning,
  error,
  success,
  info,
  muted,
  yellow: warning,
  red: error,
  toolTitle: (s) => chalk.bold(warning(s)),
  toolArgs: muted,
  toolOutput: identity,
  toolPendingBg: surfaceStyle("toolPending"),
  toolErrorBg: surfaceStyle("toolError"),
  toolSuccessBg: surfaceStyle("toolSuccess"),
  selection: chalk.bold.bgCyan.black,
  bold: chalk.bold,
  italic: chalk.italic,
  underline: chalk.underline,
  // Preserve SGR 2 dimming: ModalVeilHost relies on true terminal faintness.
  dim: chalk.dim,
};

/** Wire-role vocabulary negotiated with extensions. */
export function roleStyle(role: string): StyleFn {
  switch (role) {
    case "accent": return theme.accent;
    case "warning": return theme.warning;
    case "error": return theme.error;
    case "success": return theme.success;
    case "info": return theme.info;
    case "muted": return theme.muted;
    default: return identity;
  }
}

/** Markdown takes stable callbacks, so existing messages adapt on repaint. */
export const markdownTheme: MarkdownTheme = {
  heading: (s) => chalk.bold(accent(s)),
  link: accent,
  linkUrl: muted,
  code: warning,
  codeBlock: muted,
  codeBlockBorder: muted,
  quote: (s) => chalk.italic(muted(s)),
  quoteBorder: muted,
  hr: muted,
  listBullet: accent,
  bold: chalk.bold,
  italic: chalk.italic,
  strikethrough: chalk.strikethrough,
  underline: chalk.underline,
};
