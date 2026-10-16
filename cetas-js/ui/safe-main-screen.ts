/**
 * Final Cetas-owned display-column boundary for pi-tui's main-screen renderer.
 *
 * pi-tui 1.3.0 still calls stop() and throws when a differential update contains
 * a line wider than terminal.columns. Such a presentation error must never
 * turn a healthy Agent operation into a fatal process exit.
 *
 * The root render is normalized before pi-tui's full/differential redraw and
 * before it composites overlays (which have their own width-aware compositor).
 * Keep Kitty/iTerm2 image protocol lines byte-for-byte intact: their terminal
 * width is not the visibleWidth of the payload.
 */
import { TuiMainScreen, sliceByColumn, visibleWidth } from "@earendil-works/pi-tui";

// pi-tui 1.3.0 resolves fake-cursor APC spans *after* the root render.
// A truncated span must retain its closing marker, or reverse-video styling
// can bleed into subsequent cells when the TUI resolves it.
const FAKE_CURSOR_START = "\x1b_pi:fc\x07";
const FAKE_CURSOR_END = "\x1b_pi:/fc\x07";

const OSC133_END = /((?:\x1b\]133;[A-D](?:\x07|\x1b\\))+)$/;

export function fitTerminalLine(line: string, width: number): string {
  if (line.includes("\x1b_G") || line.includes("\x1b]1337;File=")) return line;
  if (width <= 0) return "";
  if (visibleWidth(line) <= width) return line;
  // sliceByColumn is grapheme/ANSI aware. Reset a possibly active style or
  // hyperlink after the cut; preserve shell-integration boundary markers that
  // follow the final visible glyph (and hence fall outside the slice).
  const markers = line.match(OSC133_END)?.[0] ?? "";
  const clipped = sliceByColumn(line, 0, width, true);
  const fakeCursorOpen = clipped.lastIndexOf(FAKE_CURSOR_START) >
    clipped.lastIndexOf(FAKE_CURSOR_END);
  return clipped + (fakeCursorOpen ? FAKE_CURSOR_END : "") +
    "\x1b[0m\x1b]8;;\x07" + markers;
}

export function fitTerminalLines(lines: readonly string[], width: number): string[] {
  return lines.map((line) => fitTerminalLine(line, width));
}

export class CetasTuiMainScreen extends TuiMainScreen {
  override render(width: number): string[] {
    if (width <= 0) return [];
    return fitTerminalLines(super.render(width), width);
  }
}
