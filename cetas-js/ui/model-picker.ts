/**
 * Model selection UI for cetas-js.
 *
 * The picker only understands the provider-neutral `/model` command result:
 * slot id/label/model and the provider-advertised effort values.  It never
 * reads credentials, endpoints, or provider implementation details.
 */

import {
  SelectList,
  Text,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import chalk from "chalk";

import { theme } from "./theme.ts";

export interface ModelCatalogEntry {
  id: string;
  label: string;
  provider?: string;
  model?: string;
  active: boolean;
  activeEffort?: string;
  efforts: readonly string[];
}

export interface ModelSelection {
  slot: string;
  effort?: string;
}

export interface ModelPickerTui {
  showOverlay(component: Component, options?: {
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

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function boolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${path} must be a boolean`);
  return value;
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return string(value, path);
}

/** Parse a `/model` CommandOutcome and reject malformed provider output. */
export function parseModelPickerOutcome(raw: string):
  | { type: "success"; feedback?: string; entries: ModelCatalogEntry[] }
  | { type: "failure"; reason: string }
  | { type: "needs_input"; prompt: string } {
  const value: unknown = JSON.parse(raw);
  const outcome = record(value, "model outcome");
  const type = string(outcome.type, "model outcome.type");
  if (type === "failure") {
    return { type, reason: string(outcome.reason, "model outcome.reason") };
  }
  if (type === "needs_input") {
    return {
      type,
      prompt: string(outcome.prompt ?? "", "model outcome.prompt"),
    };
  }
  if (type !== "success") {
    throw new Error(`model outcome.type is unsupported: ${type}`);
  }
  const structured = outcome.structured;
  if (!Array.isArray(structured)) {
    throw new Error("model outcome.structured must be a model catalog array");
  }
  const entries = structured.map((rawEntry, index) => {
    const path = `model outcome.structured[${index}]`;
    const entry = record(rawEntry, path);
    const rawEfforts = entry.thinking_efforts;
    if (!Array.isArray(rawEfforts)) {
      throw new Error(`${path}.thinking_efforts must be an array`);
    }
    return {
      id: string(entry.id, `${path}.id`),
      label: string(entry.label, `${path}.label`),
      provider: optionalString(entry.provider, `${path}.provider`),
      model: optionalString(entry.model, `${path}.model`),
      active: boolean(entry.active, `${path}.active`),
      activeEffort: optionalString(entry.active_effort, `${path}.active_effort`),
      efforts: rawEfforts.map((effort, effortIndex) =>
        string(effort, `${path}.thinking_efforts[${effortIndex}]`),
      ),
    } satisfies ModelCatalogEntry;
  });
  return {
    type,
    feedback: optionalString(outcome.feedback, "model outcome.feedback"),
    entries,
  };
}

interface ModelRow {
  entry: ModelCatalogEntry;
  effortIndex: number;
}

/** Provider tabs with active filled background and narrow-terminal scrolling. */
class ProviderTabStrip implements Component {
  constructor(
    private readonly tabs: readonly string[],
    private readonly active: () => number,
  ) {}

  render(width: number): string[] {
    if (this.tabs.length === 0) return [""];
    const active = this.active();
    const labels = this.tabs.map((label, index) => {
      const text = ` ${label} `;
      return index === active ? chalk.bgCyan.black(text) : chalk.gray(text);
    });
    const widths = labels.map((label) => visibleWidth(label));
    const total = widths.reduce((sum, value) => sum + value, 0) + Math.max(0, labels.length - 1);
    if (total <= width) return [labels.join(" ")];

    const available = Math.max(4, width - 2);
    let start = active;
    let end = active + 1;
    let used = widths[active] ?? 0;
    while (start > 0 || end < labels.length) {
      const left = start > 0 ? (widths[start - 1] ?? 0) + 1 : Number.POSITIVE_INFINITY;
      const right = end < labels.length ? (widths[end] ?? 0) + 1 : Number.POSITIVE_INFINITY;
      if (used + Math.min(left, right) > available) break;
      if (left <= right && start > 0) {
        start -= 1;
        used += left;
      } else if (end < labels.length) {
        end += 1;
        used += right;
      } else {
        break;
      }
    }
    const clipped = `${start > 0 ? "< " : ""}${labels.slice(start, end).join(" ")}${end < labels.length ? " >" : ""}`;
    return [truncateToWidth(clipped, width, "")];
  }

  handleInput(_data: string): void {}

  invalidate(): void {}
}

/**
 * Kimi-Code-style model selector: All/provider tabs, independent vertical
 * cursors, and horizontal effort segments for the selected model.
 */
class TabbedPickerPanel implements Component {
  focused = false;
  private readonly tabs: string[];
  private activeTab = 0;
  private readonly rowsByTab = new Map<string, ModelRow[]>();
  private readonly selectedByTab = new Map<string, number>();
  private readonly listsByTab = new Map<string, SelectList>();
  private readonly tabStrip: ProviderTabStrip;
  private readonly title: Text;
  private onSelect: (selection: ModelSelection) => void;
  private onCancel: () => void;

  constructor(
    entries: readonly ModelCatalogEntry[],
    onSelect: (selection: ModelSelection) => void,
    onCancel: () => void,
  ) {
    this.tabs = ["All"];
    for (const entry of entries) {
      const provider = entry.provider ?? "unknown";
      if (!this.tabs.includes(provider)) this.tabs.push(provider);
    }
    this.onSelect = onSelect;
    this.onCancel = onCancel;
    this.title = new Text(theme.brandBold("Select model and effort"), 1, 1);
    this.tabStrip = new ProviderTabStrip(this.tabs, () => this.activeTab);

    const allRows = entries.map((entry) => ({ entry, effortIndex: this.initialEffortIndex(entry) }));
    this.rowsByTab.set("All", allRows);
    for (const tab of this.tabs.slice(1)) {
      this.rowsByTab.set(
        tab,
        allRows.filter((row) => (row.entry.provider ?? "unknown") === tab),
      );
    }
    for (const tab of this.tabs) {
      const rows = this.rowsByTab.get(tab) ?? [];
      const selected = Math.max(0, rows.findIndex((row) => row.entry.active));
      this.selectedByTab.set(tab, selected);
      this.listsByTab.set(tab, this.makeList(tab, rows, selected));
    }
  }

  render(width: number): string[] {
    const tab = this.tabs[this.activeTab]!;
    const list = this.listsByTab.get(tab);
    if (list === undefined) throw new Error(`model picker tab missing list: ${tab}`);
    return [
      ...this.title.render(width),
      "",
      ...this.tabStrip.render(width),
      "",
      ...list.render(width),
    ];
  }

  handleInput(data: string): void {
    if (matchesKey(data, "shift+tab")) {
      this.switchTab(-1);
      return;
    }
    if (matchesKey(data, "tab")) {
      this.switchTab(1);
      return;
    }
    if (matchesKey(data, "escape")) {
      this.onCancel();
      return;
    }
    const tab = this.tabs[this.activeTab]!;
    const rows = this.rowsByTab.get(tab) ?? [];
    const selected = this.selectedByTab.get(tab) ?? 0;
    if (matchesKey(data, "up") || matchesKey(data, "down")) {
      if (rows.length === 0) return;
      const next = matchesKey(data, "up")
        ? (selected + rows.length - 1) % rows.length
        : (selected + 1) % rows.length;
      this.selectedByTab.set(tab, next);
      this.listsByTab.get(tab)?.setSelectedIndex(next);
      return;
    }
    if (matchesKey(data, "left") || matchesKey(data, "right")) {
      const row = rows[selected];
      if (row === undefined || row.entry.efforts.length === 0) return;
      const count = row.entry.efforts.length;
      row.effortIndex = matchesKey(data, "left")
        ? (row.effortIndex + count - 1) % count
        : (row.effortIndex + 1) % count;
      this.listsByTab.set(tab, this.makeList(tab, rows, selected));
      return;
    }
    if (matchesKey(data, "enter")) {
      const row = rows[selected];
      if (row === undefined) return;
      const effort = row.entry.efforts[row.effortIndex];
      this.onSelect({
        slot: row.entry.id,
        ...(effort === undefined ? {} : { effort }),
      });
    }
  }

  invalidate(): void {
    this.title.invalidate();
    for (const list of this.listsByTab.values()) list.invalidate();
  }

  /** Test hook and bridge-independent way to inspect the active tab. */
  get activeProvider(): string {
    return this.tabs[this.activeTab]!;
  }

  private switchTab(delta: number): void {
    this.activeTab = (this.activeTab + delta + this.tabs.length) % this.tabs.length;
  }

  private initialEffortIndex(entry: ModelCatalogEntry): number {
    if (entry.efforts.length === 0) return 0;
    const active = entry.activeEffort ?? entry.efforts[0];
    const index = entry.efforts.indexOf(active);
    return index < 0 ? 0 : index;
  }

  private makeList(tab: string, rows: readonly ModelRow[], selected: number): SelectList {
    const items: SelectItem[] = rows.map((row) => {
      const effort = row.entry.efforts[row.effortIndex];
      const effortText = effort === undefined ? "" : ` · effort: ${effort}`;
      // Provider-owned labels usually embed the model id already ("DeepSeek /
      // deepseek-v4-pro"); repeat it only when the label does not, so the
      // effort suffix stays inside the primary column instead of duplicating.
      const modelText =
        row.entry.model !== undefined && !row.entry.label.includes(row.entry.model)
          ? ` · ${row.entry.model}`
          : "";
      return {
        value: row.entry.id,
        label: `${row.entry.active ? "* " : "  "}${row.entry.label}${modelText}${effortText}`,
        description: row.entry.provider ?? tab,
      };
    });
    // The SelectList default locks the primary column to 32 chars, which
    // truncates ` · effort: X` off real provider labels. Widen the column so
    // the effort segment stays visible; it still clamps to the overlay width.
    const list = new SelectList(items, Math.min(12, Math.max(1, items.length)), selectTheme, {
      minPrimaryColumnWidth: 32,
      maxPrimaryColumnWidth: 64,
    });
    list.setSelectedIndex(selected);
    return list;
  }
}

/** A focused pi-tui overlay that returns one provider-neutral model choice. */
export class ModelPickerOverlay {
  private handle?: OverlayHandle;
  private panel?: TabbedPickerPanel;

  constructor(private readonly tui: ModelPickerTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(
    entries: readonly ModelCatalogEntry[],
    onSelect: (selection: ModelSelection) => void,
    onCancel: () => void,
  ): void {
    if (this.handle !== undefined) {
      throw new Error("model picker is already open");
    }
    if (entries.length === 0) {
      throw new Error("cannot open model picker with an empty catalog");
    }
    let settled = false;
    const close = () => {
      if (settled) return;
      settled = true;
      this.hide();
    };
    const panel = new TabbedPickerPanel(
      entries,
      (selection) => {
        close();
        onSelect(selection);
      },
      () => {
        close();
        onCancel();
      },
    );
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
