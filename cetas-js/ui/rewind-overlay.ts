/**
 * Rewind picker UI for cetas-js.
 *
 * Lists the user messages of the current transcript (enumerated by
 * `listRewindPoints` in src/transcript/rewind-points.ts) and returns the
 * chosen `RewindPoint` — the host then truncates the session back to that
 * message. Pure component: it reads nothing from disk and owns no
 * transcript state.
 */

import {
  SelectList,
  Text,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";

import type { RewindPoint } from "../src/transcript/rewind-points.ts";
import { translateSelectArrows } from "./select-nav.ts";
import { theme } from "./theme.ts";

export interface RewindTui {
  showOverlay(component: Component, options: {
    width?: number | `${number}%`;
    maxHeight?: number | `${number}%`;
    anchor?: "center" | "top-left" | "top-right" | "bottom-left" | "bottom-right" | "top-center" | "bottom-center" | "left-center" | "right-center";
    margin?: number;
  }): OverlayHandle;
  requestRender(): void;
}

const selectTheme: SelectListTheme = {
  selectedPrefix: (value) => theme.accent(value),
  selectedText: (value) => theme.accent(value),
  description: (value) => theme.muted(value),
  scrollInfo: (value) => theme.muted(value),
  noMatch: (value) => theme.error(value),
};

/** Keep labels inside the list's 64-char primary column. */
const LABEL_MAX = 64;

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

class RewindPanel implements Component {
  private readonly title: Text;
  private readonly list: SelectList;
  private readonly footer: Text;

  constructor(
    points: readonly RewindPoint[],
    private readonly pick: (point: RewindPoint) => void,
    private readonly close: () => void,
  ) {
    this.title = new Text(
      theme.brandBold("Rewind") + theme.muted(" to a previous message"),
      1,
      0,
    );
    const items: SelectItem[] = points.map((point) => ({
      value: String(point.messageIndex),
      label: clip(point.preview, LABEL_MAX),
      description: `message #${point.messageIndex}`,
    }));
    this.list = new SelectList(items, Math.min(points.length, 12), selectTheme, {
      minPrimaryColumnWidth: 40,
      maxPrimaryColumnWidth: 64,
    });
    this.list.onSelect = (item) => {
      this.close();
      const chosen = points.find((p) => String(p.messageIndex) === item.value);
      if (chosen) this.pick(chosen);
    };
    this.list.onCancel = () => this.close();
    this.footer = new Text(
      theme.muted("←→/↑↓ choose · ⏎ confirm · esc cancel"),
      1,
      0,
    );
  }

  render(width: number): string[] {
    return [
      ...this.title.render(width),
      ...this.list.render(width),
      ...this.footer.render(width),
    ];
  }

  handleInput(data: string): void {
    this.list.handleInput(translateSelectArrows(data));
  }

  invalidate(): void {
    this.title.invalidate();
    this.list.invalidate();
    this.footer.invalidate();
  }
}

/** A focused pi-tui overlay that returns one rewind point. */
export class RewindOverlay {
  private handle?: OverlayHandle;
  private panel?: RewindPanel;

  constructor(private readonly tui: RewindTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(
    points: readonly RewindPoint[],
    onPick: (point: RewindPoint) => void,
    onClose: () => void,
  ): void {
    if (this.handle !== undefined) {
      throw new Error("rewind overlay is already open");
    }
    // Nothing to rewind to: dismiss immediately instead of showing an empty list.
    if (points.length === 0) {
      onClose();
      return;
    }
    let settled = false;
    const close = () => {
      if (settled) return;
      settled = true;
      this.hide();
      onClose();
    };
    const panel = new RewindPanel(points, onPick, close);
    this.panel = panel;
    this.handle = this.tui.showOverlay(panel, {
      width: "76%",
      maxHeight: "70%",
      anchor: "center",
      margin: 1,
    });
    this.tui.requestRender();
  }

  hide(): void {
    const handle = this.handle;
    this.handle = undefined;
    this.panel = undefined;
    handle?.hide();
    this.tui.requestRender();
  }
}
