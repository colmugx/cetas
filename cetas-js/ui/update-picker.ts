/**
 * /update confirmation UI for cetas-js.
 *
 * Three fixed choices over a fresh check result: apply the update (the shell
 * then hands the terminal to the package manager), print the copyable
 * install command, or skip. The picker knows nothing about registries or
 * install mechanics.
 */

import {
  SelectList,
  Text,
  matchesKey,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";

export interface UpdateTui {
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

export type UpdateChoice = "update" | "command" | "skip";

class UpdatePanel implements Component {
  private readonly title: Text;
  private readonly list: SelectList;
  private readonly footer: Text;

  constructor(
    currentVersion: string,
    latestVersion: string,
    installCommand: string,
    private readonly choose: (choice: UpdateChoice) => void,
    private readonly close: () => void,
  ) {
    this.title = new Text(
      theme.brandBold("Update available") +
        theme.muted(`  — cetas ${currentVersion} → ${latestVersion}`),
      1,
      0,
    );
    const items: SelectItem[] = [
      { value: "update", label: `Update now (runs \`${installCommand}\`)` },
      { value: "command", label: "Show command", description: "Print the install command to copy" },
      { value: "skip", label: "Skip", description: "Decide later with /update" },
    ];
    this.list = new SelectList(items, items.length, selectTheme);
    this.list.onSelect = (item) => {
      this.close();
      this.choose(item.value as UpdateChoice);
    };
    this.list.onCancel = () => this.close();
    this.footer = new Text(
      theme.muted("↑↓ browse · enter confirm · esc skip · the session persists across the update"),
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
    // 'q' mirrors the esc dismissal for vi muscle memory; everything else is
    // SelectList navigation (the list is vertical, only up/down move it).
    if (matchesKey(data, "q")) {
      this.close();
      return;
    }
    this.list.handleInput(data);
  }

  invalidate(): void {
    this.title.invalidate();
    this.list.invalidate();
    this.footer.invalidate();
  }
}

/** Focused overlay returning the user's update choice. */
export class UpdateOverlay {
  private handle?: OverlayHandle;
  private panel?: UpdatePanel;

  constructor(private readonly tui: UpdateTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(
    currentVersion: string,
    latestVersion: string,
    installCommand: string,
    choose: (choice: UpdateChoice) => void,
    onClose: () => void,
  ): void {
    if (this.handle !== undefined) {
      throw new Error("update overlay is already open");
    }
    let settled = false;
    const close = () => {
      if (settled) return;
      settled = true;
      this.hide();
      onClose();
    };
    const panel = new UpdatePanel(currentVersion, latestVersion, installCommand, choose, close);
    this.panel = panel;
    this.handle = this.tui.showOverlay(panel, {
      width: "76%",
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
