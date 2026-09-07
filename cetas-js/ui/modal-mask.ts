/**
 * Full-screen dim veil behind centered modals.
 *
 * pi-tui overlays composite as opaque rectangles over the rendered base, and
 * an overlay's render() only sees the terminal width — it cannot restyle what
 * sits underneath. The veil therefore re-renders the base children itself and
 * emits the visible viewport flattened to a faint gray: a terminal-safe
 * "dimmed background" behind every modal. It is nonCapturing (keyboard stays
 * with the modal) and shown below the modal because it enters the overlay
 * stack first; compositing paints higher focusOrder on top.
 */

import type {
  Component,
  OverlayHandle,
  OverlayOptions,
} from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";

/**
 * The TUI surface the veil needs. The real pi-tui TUI satisfies this
 * structurally; tests substitute a fake.
 */
export interface VeilTui {
  render(width: number): string[];
  readonly terminal: { readonly rows: number; readonly columns: number };
  showOverlay(component: Component, options?: OverlayOptions): OverlayHandle;
  requestRender(): void;
}

/** Match OSC (hyperlinks/titles), CSI (SGR/cursor), APC, and bare escapes. */
const ESCAPE_PATTERN = new RegExp(
  [
    "\\u001b\\][^\\u0007\\u001b]*(?:\\u0007|\\u001b\\\\)",
    "\\u001b\\[[0-9;:?<=>!]*[\\u0020-\\u002f]*[@-~]",
    "\\u001b_[^\\u0007\\u001b]*(?:\\u0007|\\u001b\\\\)",
    "\\u001b[@-Z\\u005c-_]",
  ].join("|"),
  "g",
);

/** Base line → plain text with colors/backgrounds faint gray. */
export function dimLine(line: string): string {
  const flat = line.replace(ESCAPE_PATTERN, "");
  if (flat.trim().length === 0) return "";
  return theme.muted(theme.dim(flat));
}

/** Renders the visible viewport of the base content, dimmed. */
class DimVeil implements Component {
  constructor(private readonly tui: VeilTui) {}

  render(width: number): string[] {
    const rows = Math.max(1, this.tui.terminal.rows);
    const base = this.tui.render(width);
    const lines: string[] = [];
    for (let i = Math.max(0, base.length - rows); i < base.length; i++) {
      lines.push(dimLine(base[i] ?? ""));
    }
    while (lines.length < rows) lines.push("");
    return lines.slice(0, rows);
  }

  invalidate(): void {}
}

/**
 * Modal entry point for the shell: every overlay-style popup goes through
 * here, so the veil's lifetime is reference-counted across stacked pickers
 * (provider → method, oauth progress) and ends when the last handle hides.
 */
export class ModalVeilHost {
  private veilHandle?: OverlayHandle;
  private openModals = 0;

  constructor(private readonly tui: VeilTui) {}

  showOverlay(component: Component, options?: OverlayOptions): OverlayHandle {
    this.ensureVeil();
    this.openModals += 1;
    const host = this;
    const inner = this.tui.showOverlay(component, options);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      host.openModals -= 1;
      if (host.openModals === 0) {
        host.veilHandle?.hide();
        host.veilHandle = undefined;
        host.tui.requestRender();
      }
    };
    return {
      hide: () => {
        inner.hide();
        release();
      },
      setHidden: (hidden) => inner.setHidden(hidden),
      isHidden: () => inner.isHidden(),
      focus: () => inner.focus(),
      unfocus: (unfocusOptions) => inner.unfocus(unfocusOptions),
      isFocused: () => inner.isFocused(),
      getBounds: () => inner.getBounds(),
    };
  }

  requestRender(): void {
    this.tui.requestRender();
  }

  private ensureVeil(): void {
    if (this.veilHandle !== undefined) return;
    this.veilHandle = this.tui.showOverlay(new DimVeil(this.tui), {
      width: "100%",
      anchor: "top-left",
      margin: 0,
      nonCapturing: true,
    });
  }
}
