/**
 * Model selection UI for cetas-js.
 *
 * The picker only understands the provider-neutral `/model` command result:
 * slot id/label/model, the provider-advertised effort values, optional
 * provider quota readings, and optional provider-declared pricing facts.
 * It never reads credentials, endpoints, or provider implementation details.
 */

import {
  Input,
  SelectList,
  Text,
  fuzzyFilter,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import chalk from "chalk";

import { theme } from "./theme.ts";

import {
  type EntryPricing,
  type ModelCatalogEntry,
  type ModelSelection,
} from "./model-catalog.ts";
import {
  classifyProviderQuota,
  isQuotaExhausted,
  quickPickGroups,
  formatQuotaAge,
  formatQuotaReset,
  type ProviderQuotaClass,
} from "./model-quota.ts";

/** Legacy public surface stays stable while the modules gain separate responsibilities. */
export {
  parseModelPickerOutcome,
  formatPickCandidateNotices,
} from "./model-catalog.ts";
export type {
  ProviderQuotaReading, EntryPricing, PickCandidate, ModelCatalogEntry, ModelSelection,
} from "./model-catalog.ts";
export {
  classifyProviderQuota, isQuotaExhausted, quickPickGroups, formatQuotaAge, formatQuotaReset,
} from "./model-quota.ts";
export type { ProviderQuotaWindow, ProviderQuotaClass, QuickPickGroup } from "./model-quota.ts";

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

interface ModelRow {
  entry: ModelCatalogEntry;
  effortIndex: number;
  disabled: boolean;
}

/** Picker-row pricing badge. Peak: red multiplier plus a dim parenthesized
 * window naming the surcharge period. Off-peak: green multiplier only.
 * No provider-declared pricing renders no badge. */
export function renderPricingBadge(pricing: EntryPricing | undefined): string {
  if (pricing === undefined) return "";
  if (pricing.tier === "peak") {
    return ` ${theme.red(pricing.multiplier)} ${theme.dim(`(${pricing.window})`)}`;
  }
  return ` ${theme.success(pricing.multiplier)}`;
}

/** Integers print exactly as stated ("90", never "90.0"). */
function formatLeftPercent(leftPercent: number): string {
  return String(leftPercent);
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
 * Model selector: All/provider tabs with independent vertical option
 * lists, plus horizontal effort segments for the selected model.
 * Typing any printable character opens a fuzzy search across every tab;
 * escape first clears the query, then cancels the picker.
 * Quota mode replaces the tabs with Limit/Balance/Other quick-pick groups
 * ranked by provider quota, preselecting each group's active entry when it
 * is selectable (else its first selectable row); 5h-exhausted rows stay at
 * the bottom of the Limit tab, disabled.
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
  private searchInput?: Input;
  private searchRows: ModelRow[] = [];
  private searchIndex = 0;
  private searchList?: SelectList;
  private readonly searchBase: ModelRow[];
  private readonly quotaClassByProvider = new Map<string, ProviderQuotaClass | undefined>();
  private onSelect: (selection: ModelSelection) => void;
  private onCancel: () => void;

  constructor(
    entries: readonly ModelCatalogEntry[],
    onSelect: (selection: ModelSelection) => void,
    onCancel: () => void,
    private readonly now: () => Date = () => new Date(),
    private readonly mode: "tabs" | "quota" = "tabs",
  ) {
    this.onSelect = onSelect;
    this.onCancel = onCancel;
    this.title = new Text(theme.brandBold("Select model and effort"), 1, 1);
    if (this.mode === "quota") {
      const readingsByProvider = new Map<string, ProviderQuotaReading[]>();
      for (const entry of entries) {
        const provider = entry.provider ?? "unknown";
        const bucket = readingsByProvider.get(provider);
        if (bucket === undefined) {
          readingsByProvider.set(provider, [...(entry.quotaReadings ?? [])]);
        } else if (entry.quotaReadings !== undefined) {
          bucket.push(...entry.quotaReadings);
        }
      }
      for (const [provider, readings] of readingsByProvider) {
        this.quotaClassByProvider.set(provider, classifyProviderQuota(readings));
      }
      const groups = quickPickGroups(entries);
      this.tabs = groups.map((group) => group.label);
      const ordered: ModelRow[] = [];
      let activeGroup: string | undefined;
      for (const group of groups) {
        const rows = group.entries.map((entry) => ({
          entry,
          effortIndex: this.initialEffortIndex(entry),
          disabled: isQuotaExhausted(this.quotaClassByProvider.get(entry.provider ?? "unknown")),
        }));
        this.rowsByTab.set(group.label, rows);
        ordered.push(...rows);
        // The desc quota rank already sinks exhausted rows to the group's
        // bottom; the cursor prefers the group's active entry when it is
        // selectable and falls back to the first selectable row (0 when the
        // tab is entirely disabled). The `*` active marker stays as-is.
        const activeIdx = rows.findIndex((row) => row.entry.active && !row.disabled);
        const firstSelectable = rows.findIndex((row) => !row.disabled);
        const selected =
          activeIdx >= 0 ? activeIdx : firstSelectable < 0 ? 0 : firstSelectable;
        if (activeIdx >= 0 && activeGroup === undefined) activeGroup = group.label;
        this.selectedByTab.set(group.label, selected);
        this.listsByTab.set(group.label, this.makeList(group.label, rows, selected));
      }
      // The default tab follows the selectable active entry when one exists;
      // otherwise it must offer a usable choice — Other rows are never
      // disabled, so a selectable tab always exists (0 as defense).
      this.activeTab = Math.max(
        0,
        activeGroup === undefined
          ? this.tabs.findIndex((tab) => (this.rowsByTab.get(tab) ?? []).some((row) => !row.disabled))
          : this.tabs.indexOf(activeGroup),
      );
      // Disabled rows are inert: keep them out of fuzzy search entirely.
      this.searchBase = ordered.filter((row) => !row.disabled);
    } else {
      this.tabs = ["All"];
      for (const entry of entries) {
        const tab = entry.group ?? entry.provider ?? "unknown";
        if (!this.tabs.includes(tab)) this.tabs.push(tab);
      }
      const allRows = entries.map((entry) => ({
        entry,
        effortIndex: this.initialEffortIndex(entry),
        disabled: false,
      }));
      this.rowsByTab.set("All", allRows);
      for (const tab of this.tabs.slice(1)) {
        this.rowsByTab.set(
          tab,
          allRows.filter((row) => (row.entry.group ?? row.entry.provider ?? "unknown") === tab),
        );
      }
      for (const tab of this.tabs) {
        const rows = this.rowsByTab.get(tab) ?? [];
        const selected = Math.max(0, rows.findIndex((row) => row.entry.active));
        this.selectedByTab.set(tab, selected);
        this.listsByTab.set(tab, this.makeList(tab, rows, selected));
      }
      this.searchBase = allRows;
    }
    this.tabStrip = new ProviderTabStrip(this.tabs, () => this.activeTab);
  }

  render(width: number): string[] {
    if (this.isSearchVisible()) {
      const list = this.searchList;
      if (list === undefined) throw new Error("model picker search missing list");
      const count = this.searchRows.length;
      const matchText = count === 1 ? "1 match" : `${count} matches`;
      return [
        ...this.title.render(width),
        "",
        ...this.searchInput!.render(width),
        theme.muted(`  ${matchText}`),
        "",
        ...list.render(width),
      ];
    }
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
      if (this.isSearchVisible()) {
        this.searchInput!.setValue("");
        this.refreshSearch();
      } else {
        this.onCancel();
      }
      return;
    }
    if (this.isSearchVisible()) {
      this.handleSearchInput(data);
    } else {
      this.handleTabInput(data);
    }
  }

  /** Keys while a query is live: up/down move the match cursor, left/right
   * rotate effort, enter confirms; every other key edits the query. */
  private handleSearchInput(data: string): void {
    if (matchesKey(data, "up") || matchesKey(data, "down")) {
      if (this.searchRows.length === 0) return;
      const next = matchesKey(data, "up")
        ? (this.searchIndex + this.searchRows.length - 1) % this.searchRows.length
        : (this.searchIndex + 1) % this.searchRows.length;
      this.searchIndex = next;
      this.searchList?.setSelectedIndex(next);
      return;
    }
    if (matchesKey(data, "left") || matchesKey(data, "right")) {
      const row = this.searchRows[this.searchIndex];
      if (row === undefined || row.entry.efforts.length === 0) return;
      row.effortIndex = this.rotatedEffortIndex(row, matchesKey(data, "left"));
      this.searchList = this.makeList(this.searchTab(), this.searchRows, this.searchIndex);
      return;
    }
    if (matchesKey(data, "enter")) {
      this.confirmRow(this.searchRows[this.searchIndex]);
      return;
    }
    // The keys above are consumed here, so the query input receives only
    // character data and its supported edit chords (backspace, word deletes,
    // undo).
    this.searchInput!.handleInput(data);
    this.refreshSearch();
  }

  private handleTabInput(data: string): void {
    const tab = this.tabs[this.activeTab]!;
    const rows = this.rowsByTab.get(tab) ?? [];
    const selected = this.selectedByTab.get(tab) ?? 0;
    if (matchesKey(data, "up") || matchesKey(data, "down")) {
      if (rows.length === 0) return;
      const down = matchesKey(data, "down");
      // Cyclic, but disabled rows are skipped; a fully disabled tab keeps
      // its cursor.
      let next = selected;
      for (let step = 0; step < rows.length; step += 1) {
        next = down ? (next + 1) % rows.length : (next + rows.length - 1) % rows.length;
        if (!rows[next]!.disabled) break;
      }
      if (rows[next]!.disabled) return;
      this.selectedByTab.set(tab, next);
      this.listsByTab.get(tab)?.setSelectedIndex(next);
      return;
    }
    if (matchesKey(data, "left") || matchesKey(data, "right")) {
      const row = rows[selected];
      if (row === undefined || row.disabled || row.entry.efforts.length === 0) return;
      row.effortIndex = this.rotatedEffortIndex(row, matchesKey(data, "left"));
      this.listsByTab.set(tab, this.makeList(tab, rows, selected));
      return;
    }
    if (matchesKey(data, "enter")) {
      this.confirmRow(rows[selected]);
      return;
    }
    if (this.isPrintable(data)) {
      if (this.searchInput === undefined) {
        const input = new Input();
        input.focused = true;
        this.searchInput = input;
      }
      this.searchInput.handleInput(data);
      this.refreshSearch();
    }
  }

  invalidate(): void {
    this.title.invalidate();
    for (const list of this.listsByTab.values()) list.invalidate();
    this.searchInput?.invalidate();
    this.searchList?.invalidate();
  }

  /** Test hook and bridge-independent way to inspect the active tab. */
  get activeProvider(): string {
    return this.tabs[this.activeTab]!;
  }

  private switchTab(delta: number): void {
    this.activeTab = (this.activeTab + delta + this.tabs.length) % this.tabs.length;
  }

  private confirmRow(row: ModelRow | undefined): void {
    if (row === undefined || row.disabled) return;
    const effort = row.entry.efforts[row.effortIndex];
    this.onSelect({
      slot: row.entry.id,
      ...(effort === undefined ? {} : { effort }),
    });
  }

  private rotatedEffortIndex(row: ModelRow, left: boolean): number {
    const count = row.entry.efforts.length;
    return left ? (row.effortIndex + count - 1) % count : (row.effortIndex + 1) % count;
  }

  private isSearchVisible(): boolean {
    return this.searchInput !== undefined && this.searchInput.getValue() !== "";
  }

  /** Description fallback for search rows: quota mode uses the active group;
   * tabs mode uses "All". */
  private searchTab(): string {
    return this.mode === "quota" ? this.tabs[this.activeTab]! : "All";
  }

  /** Re-derive the filtered rows and list after any query change. */
  private refreshSearch(): void {
    const query = this.searchInput?.getValue() ?? "";
    this.searchRows = fuzzyFilter(
      this.searchBase,
      query,
      (row) => this.searchText(row),
    );
    this.searchIndex = 0;
    this.searchList = this.makeList(this.searchTab(), this.searchRows, this.searchIndex);
    if (query === "") {
      // Lists bake the current effort into their row labels, so the tabbed
      // lists must be rebuilt to surface effort rotations made in search.
      for (const tab of this.tabs) {
        this.listsByTab.set(
          tab,
          this.makeList(tab, this.rowsByTab.get(tab) ?? [], this.selectedByTab.get(tab) ?? 0),
        );
      }
    }
  }

  private searchText(row: ModelRow): string {
    const entry = row.entry;
    return [entry.label, entry.model, entry.provider, entry.group, entry.id]
      .filter((part): part is string => part !== undefined)
      .join(" ");
  }

  /** True for plain character data: no control bytes and no escape prefix. */
  private isPrintable(data: string): boolean {
    if (data.length === 0) return false;
    return [...data].every((char) => {
      const code = char.charCodeAt(0);
      return code >= 32 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f);
    });
  }

  private initialEffortIndex(entry: ModelCatalogEntry): number {
    if (entry.efforts.length === 0) return 0;
    const active = entry.activeEffort ?? entry.defaultEffort ?? entry.efforts[0];
    const index = entry.efforts.indexOf(active);
    return index < 0 ? 0 : index;
  }

  /** Quota quick-pick row badge: primary window plus muted secondary
   * windows and staleness; severity tracks the worst window so an exhausted
   * long window reads red even while the row sorts high on its 5h headroom. */
  private quotaBadge(row: ModelRow): string {
    const cls = this.quotaClassByProvider.get(row.entry.provider ?? "unknown");
    if (cls === undefined) return ` ${theme.muted("n/a")}`;
    if (cls.kind === "balance") {
      return ` ${cls.value} ${cls.currency}${this.stalenessSuffix(cls.fetchedAtMs)}`;
    }
    const text = `${formatLeftPercent(cls.primaryLeftPercent)}% left`;
    const color =
      cls.worstLeftPercent <= 0 ? theme.error : cls.worstLeftPercent <= 20 ? theme.warning : theme.muted;
    // The primary reading can sit mid-array when no "5h" label exists; skip
    // exactly that reading, duplicates would render identically anyway.
    const primaryIndex = Math.max(
      0,
      cls.windows.findIndex(
        (w) => w.window === cls.primaryWindow && w.leftPercent === cls.primaryLeftPercent,
      ),
    );
    const others = cls.windows
      .filter((_, index) => index !== primaryIndex)
      .map((w) => theme.muted(` · ${w.window} ${formatLeftPercent(w.leftPercent)}`))
      .join("");
    return ` ${cls.primaryWindow} ${color(text)}${others}${this.stalenessSuffix(cls.fetchedAtMs)}`;
  }

  /** Quota readings older than 30 minutes carry their age. */
  private stalenessSuffix(fetchedAtMs: number): string {
    const stale = this.now().getTime() - fetchedAtMs > 30 * 60 * 1000;
    return stale ? ` ${theme.muted(formatQuotaAge(fetchedAtMs, this.now()))}` : "";
  }

  /** " resets in <rel>" for a disabled row whose reset time is still ahead. */
  private resetSuffix(row: ModelRow): string {
    const cls = this.quotaClassByProvider.get(row.entry.provider ?? "unknown");
    const resetAtMs = cls !== undefined && cls.kind === "limit" ? cls.resetAtMs : undefined;
    if (typeof resetAtMs !== "number") return "";
    const text = formatQuotaReset(resetAtMs, this.now());
    return text === "" ? "" : ` ${theme.muted(text)}`;
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
      const badge =
        this.mode === "quota"
          ? this.quotaBadge(row)
          : renderPricingBadge(row.entry.pricing);
      const marker = row.entry.active ? "* " : "  ";
      const head = `${marker}${row.entry.label}${modelText}`;
      // Disabled rows dim everything except the badge (severity color stays
      // readable) and say when the quota returns.
      const label = row.disabled
        ? `${theme.muted(head)}${badge}${this.resetSuffix(row)}${theme.muted(effortText)}`
        : `${head}${badge}${effortText}`;
      return {
        value: row.entry.id,
        label,
        description: row.entry.provider ?? tab,
      };
    });
    // The SelectList default locks the primary column to 32 chars, which
    // truncates ` · effort: X` off real provider labels. Widen the column so
    // the effort segment and pricing badge stay visible; it still clamps to
    // the overlay width.
    const list = new SelectList(items, Math.min(12, Math.max(1, items.length)), selectTheme, {
      minPrimaryColumnWidth: 32,
      maxPrimaryColumnWidth: 80,
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
    now: () => Date = () => new Date(),
    mode: "tabs" | "quota" = "tabs",
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
      now,
      mode,
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
