/**
 * Terminal-aware contrast for *fixed semantic activity roles*, not a theme.
 * An OSC 10/11/4 reply only adjusts contrast to the user's terminal colors.
 * Cetas branding, message styling, and user theme preferences are unchanged.
 */
import { foregroundAnsi, getTerminalColorMode, rgbColor, type RgbColor, type TerminalColors } from "@earendil-works/pi-tui";
import { defaultActivityStyle, type LiveActivityRole, type LiveActivityStyle } from "./live-activities.ts";

function channel(value: number): number {
  const v = value / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}
export function relativeLuminance(color: RgbColor): number {
  return channel(color.r) * 0.2126 + channel(color.g) * 0.7152 + channel(color.b) * 0.0722;
}
function contrast(fg: RgbColor, bg: RgbColor): number {
  const a = relativeLuminance(fg), b = relativeLuminance(bg);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

// Fixed semantic hues with light/dark variants, not configurable palettes.
const ROLE_COLORS: Partial<Record<LiveActivityRole, readonly [RgbColor, RgbColor]>> = {
  agent: [{ r: 64, g: 185, b: 224 }, { r: 0, g: 103, b: 151 }],
  question: [{ r: 255, g: 190, b: 82 }, { r: 148, g: 83, b: 0 }],
  wakeup: [{ r: 190, g: 147, b: 245 }, { r: 103, g: 63, b: 173 }],
  coordination: [{ r: 190, g: 147, b: 245 }, { r: 103, g: 63, b: 173 }],
  waiting: [{ r: 117, g: 214, b: 145 }, { r: 16, g: 119, b: 51 }],
};

export function createTerminalActivityStyle(colors: TerminalColors): LiveActivityStyle {
  const background = colors.background;
  if (background === undefined) return defaultActivityStyle;
  const mode = getTerminalColorMode();
  const accents = new Map<LiveActivityRole, string>();
  for (const [role, variants] of Object.entries(ROLE_COLORS) as [LiveActivityRole, readonly [RgbColor, RgbColor]][]) {
    const chosen = contrast(variants[0], background) >= contrast(variants[1], background) ? variants[0] : variants[1];
    // If the terminal reports an unusual background and both variants are
    // low-contrast, prefer the terminal's own foreground (OSC 10).
    const color = colors.foreground && contrast(chosen, background) < 4.5
      ? colors.foreground : chosen;
    accents.set(role, foregroundAnsi(rgbColor(color.r, color.g, color.b), mode));
  }
  return (role, text) => {
    const ansi = accents.get(role);
    if (!ansi) return defaultActivityStyle(role, text);
    return ansi + text + "\x1b[39m";
  };
}
