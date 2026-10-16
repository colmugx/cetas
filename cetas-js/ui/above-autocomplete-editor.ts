import {
  Editor, visibleWidth, truncateToWidth,
  type Component, type EditorTheme, type TUI,
  type TuiMouseEvent, type TuiMouseEventResult, type TerminalColors,
} from "@earendil-works/pi-tui";

/** Select background from the terminal's actual OSC 11 color rather than a fixed palette. */
export function autocompletePalette(colors: TerminalColors): { background: string; foreground: string } {
  const bg = colors.background ?? {r: 36,g: 38,b: 48};
  const fg = colors.foreground ?? {r: 210,g: 211,b: 218};
  const toward = (value: number, target: number) => Math.round(value * .86 + target * .14);
  const brightness = (bg.r * 299 + bg.g * 587 + bg.b * 114) / 1000;
  const target = brightness < 128 ? 255 : 0;
  const shade = {r:toward(bg.r,target),g:toward(bg.g,target),b:toward(bg.b,target)};
  return {
    background: `\x1b[48;2;${shade.r};${shade.g};${shade.b}m`,
    foreground: `\x1b[38;2;${fg.r};${fg.g};${fg.b}m`,
  };
}

/**
 * pi-tui 1.3 attaches autocomplete below Editor and changes its layout height.
 * Split its authoritative render into two components while leaving key
 * handling, completion selection, debounce and cursor marker on Editor.
 * The menu is placed *before* the editor in a bottom-anchored VStack; opening
 * it compresses scrollback, not the editor's screen position.
 */
export class AboveAutocompleteEditor extends Editor {
  private menu: string[] = [];
  private editorLines: string[] = [];
  private computedWidth = -1;
  private palette = autocompletePalette({});
  readonly menuComponent: Component & { handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined };

  constructor(tui: TUI, theme: EditorTheme) {
    super(tui, theme);
    this.menuComponent = {
      render: (width) => this.renderMenu(width),
      invalidate: () => { this.computedWidth = -1; },
      handleMouse: (event) => this.handleMenuMouse(event),
    };
  }

  setTerminalColors(colors: TerminalColors): void {
    this.palette = autocompletePalette(colors);
    this.computedWidth = -1;
  }

  private updateParts(width: number): void {
    const lines = super.render(width);
    const raw = this as unknown as { renderedAutocompleteHeight: number; renderedVisibleLineCount: number };
    const count = Math.max(0, raw.renderedAutocompleteHeight);
    this.editorLines = count ? lines.slice(0, -count) : lines;
    this.menu = count ? lines.slice(-count) : [];
    this.computedWidth = width;
  }

  renderMenu(width: number): string[] {
    this.updateParts(width);
    return this.menu.map(line => {
      const reset = "\x1b[0m";
      const clipped = truncateToWidth(line, width, "");
      const padding = " ".repeat(Math.max(0, width - visibleWidth(clipped)));
      return this.palette.background + this.palette.foreground +
        clipped + padding + reset;
    });
  }

  override render(width: number): string[] {
    // Reuse the rendering performed by the preceding menu layout node.
    if (this.computedWidth !== width) this.updateParts(width);
    const result = this.editorLines;
    this.computedWidth = -1;
    return result;
  }

  private handleMenuMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    const raw = this as unknown as { renderedVisibleLineCount: number };
    return super.handleMouse({
      ...event,
      y: event.y + raw.renderedVisibleLineCount + 2,
    });
  }
}
