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

/** One provider-reported quota window, normalized from the wire format. */
export interface ProviderQuotaReading {
  window: string;
  usedPercent?: number | null;
  amount?: { value: string; currency: string } | null;
  available?: boolean | null;
  resetAtMs?: number | null;
  fetchedAtMs: number;
}

/** One provider-declared peak/off-peak pricing fact for a catalog entry. */
export interface EntryPricing {
  tier: "peak" | "off-peak";
  multiplier: string;
  window: string;
}

/** One runner-up model+effort from a `/model <provider> pick` outcome. */
export interface PickCandidate {
  slotId: string;
  model: string;
  effort: string;
  iq: number;
  costUsd: number;
}

export interface ModelCatalogEntry {
  id: string;
  label: string;
  provider?: string;
  /** Provider-declared display group; when present it replaces provider as the tab. */
  group?: string;
  model?: string;
  active: boolean;
  activeEffort?: string;
  defaultEffort?: string;
  efforts: readonly string[];
  quotaReadings?: readonly ProviderQuotaReading[];
  pricing?: EntryPricing;
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

function nonEmptyString(value: unknown, path: string): string {
  const text = string(value, path);
  if (text.length === 0) throw new Error(`${path} must be a non-empty string`);
  return text;
}

function boolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${path} must be a boolean`);
  return value;
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return string(value, path);
}

function number(value: unknown, path: string): number {
  if (typeof value !== "number") throw new Error(`${path} must be a number`);
  return value;
}

function finiteNumber(value: unknown, path: string): number {
  const parsed = number(value, path);
  if (!Number.isFinite(parsed)) throw new Error(`${path} must be a finite number`);
  return parsed;
}

function optionalNumber(value: unknown, path: string): number | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return number(value, path);
}

function optionalBoolean(value: unknown, path: string): boolean | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return boolean(value, path);
}

function optionalAmount(
  value: unknown,
  path: string,
): { value: string; currency: string } | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  const amount = record(value, path);
  return {
    value: string(amount.value, `${path}.value`),
    currency: string(amount.currency, `${path}.currency`),
  };
}

function optionalQuotaReadings(
  value: unknown,
  path: string,
): ProviderQuotaReading[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new Error(`${path} must be an array`);
  return value.map((rawReading, index) => {
    const readingPath = `${path}[${index}]`;
    const reading = record(rawReading, readingPath);
    return {
      window: string(reading.window, `${readingPath}.window`),
      usedPercent: optionalNumber(reading.used_percent, `${readingPath}.used_percent`),
      amount: optionalAmount(reading.amount, `${readingPath}.amount`),
      available: optionalBoolean(reading.available, `${readingPath}.available`),
      resetAtMs: optionalNumber(reading.reset_at_ms, `${readingPath}.reset_at_ms`),
      fetchedAtMs: number(reading.fetched_at_ms, `${readingPath}.fetched_at_ms`),
    } satisfies ProviderQuotaReading;
  });
}

function optionalPricing(value: unknown, path: string): EntryPricing | undefined {
  if (value === undefined || value === null) return undefined;
  const pricing = record(value, path);
  const tier = string(pricing.tier, `${path}.tier`);
  if (tier !== "peak" && tier !== "off-peak") {
    throw new Error(`${path}.tier is unsupported: ${tier}`);
  }
  return {
    tier,
    multiplier: string(pricing.multiplier, `${path}.multiplier`),
    window: string(pricing.window, `${path}.window`),
  } satisfies EntryPricing;
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
      group: optionalString(entry.group, `${path}.group`),
      model: optionalString(entry.model, `${path}.model`),
      active: boolean(entry.active, `${path}.active`),
      activeEffort: optionalString(entry.active_effort, `${path}.active_effort`),
      defaultEffort: optionalString(entry.default_effort, `${path}.default_effort`),
      efforts: rawEfforts.map((effort, effortIndex) =>
        string(effort, `${path}.thinking_efforts[${effortIndex}]`),
      ),
      quotaReadings: optionalQuotaReadings(entry.quota_readings, `${path}.quota_readings`),
      pricing: optionalPricing(entry.pricing, `${path}.pricing`),
    } satisfies ModelCatalogEntry;
  });
  return {
    type,
    feedback: optionalString(outcome.feedback, "model outcome.feedback"),
    entries,
  };
}

function parsePickCandidate(raw: unknown, path: string): PickCandidate {
  const entry = record(raw, path);
  return {
    slotId: string(entry.slot_id, `${path}.slot_id`),
    model: nonEmptyString(entry.model, `${path}.model`),
    effort: nonEmptyString(entry.effort, `${path}.effort`),
    iq: finiteNumber(entry.iq, `${path}.iq`),
    costUsd: finiteNumber(entry.cost_usd, `${path}.cost_usd`),
  } satisfies PickCandidate;
}

/**
 * Follow-up notices for a `/model <provider> pick` outcome: one line per
 * runner-up candidate (the picked switch is announced by the command's own
 * feedback line). Payloads without candidates — every other command's
 * structured data, or a null one — produce no notices; malformed candidate
 * entries are rejected.
 */
export function formatPickCandidateNotices(structured: unknown): string[] {
  if (typeof structured !== "object" || structured === null) return [];
  const rawCandidates = (structured as Record<string, unknown>).candidates;
  if (rawCandidates === undefined || rawCandidates === null) return [];
  if (!Array.isArray(rawCandidates)) {
    throw new Error("pick outcome.candidates must be an array");
  }
  return rawCandidates.map((rawEntry, index) => {
    const candidate = parsePickCandidate(rawEntry, `pick outcome.candidates[${index}]`);
    return `candidate ${index + 2} — ${candidate.model}:${candidate.effort} · IQ ${candidate.iq.toFixed(1)} · $${candidate.costUsd.toFixed(2)}`;
  });
}

interface ModelRow {
  entry: ModelCatalogEntry;
  effortIndex: number;
  disabled: boolean;
}

/** One classified limit window: provider-stated remaining plus its times. */
export interface ProviderQuotaWindow {
  window: string;
  leftPercent: number;
  fetchedAtMs: number;
  resetAtMs?: number | null;
}

/**
 * One provider's quota reduced to quick-pick figures: a usage limit (ranked
 * by its primary window's remaining, colored by its worst window) or a
 * monetary balance. Providers with neither stay unclassified.
 */
export type ProviderQuotaClass =
  | {
      kind: "limit";
      primaryWindow: string;
      primaryLeftPercent: number;
      worstLeftPercent: number;
      windows: readonly ProviderQuotaWindow[];
      fetchedAtMs: number;
      resetAtMs?: number | null;
    }
  | { kind: "balance"; value: string; currency: string; fetchedAtMs: number };

export function classifyProviderQuota(
  readings: readonly ProviderQuotaReading[],
): ProviderQuotaClass | undefined {
  const windows: ProviderQuotaWindow[] = [];
  for (const reading of readings) {
    const used = reading.usedPercent;
    if (used === undefined || used === null) continue;
    // Exact remaining percent on the provider-stated number, the same
    // remaining convention as the status bar; absent numbers are never
    // estimated from other readings.
    windows.push({
      window: reading.window,
      leftPercent: 100 - used,
      fetchedAtMs: reading.fetchedAtMs,
      resetAtMs: reading.resetAtMs,
    });
  }
  if (windows.length === 0) {
    for (const reading of readings) {
      const amount = reading.amount;
      if (amount === undefined || amount === null) continue;
      return {
        kind: "balance",
        value: amount.value,
        currency: amount.currency,
        fetchedAtMs: reading.fetchedAtMs,
      };
    }
    return undefined;
  }
  // The "5h" label is the de-facto short-window convention across
  // codex/zai/kimi; this is presentation-layer label matching over
  // provider-stated facts, never estimation.
  const fiveHour = windows.find((w) => w.window === "5h");
  const ordered =
    fiveHour === undefined ? windows : [fiveHour, ...windows.filter((w) => w !== fiveHour)];
  let primary = ordered[0]!;
  if (fiveHour === undefined) {
    // No 5h label: fall back to the round-1 most constrained window, ties
    // keeping the first reading (covers exotic labels like kimi(<duration>)).
    for (const w of ordered) {
      if (w.leftPercent < primary.leftPercent) primary = w;
    }
  }
  return {
    kind: "limit",
    primaryWindow: primary.window,
    primaryLeftPercent: primary.leftPercent,
    worstLeftPercent: Math.min(...ordered.map((w) => w.leftPercent)),
    windows: ordered,
    fetchedAtMs: primary.fetchedAtMs,
    resetAtMs: primary.resetAtMs,
  };
}

/**
 * True only when a limit class's primary window has nothing left; quota
 * mode renders such rows disabled at the bottom of the Limit tab.
 */
export function isQuotaExhausted(cls: ProviderQuotaClass | undefined): boolean {
  return cls?.kind === "limit" && cls.primaryLeftPercent <= 0;
}

export interface QuickPickGroup {
  kind: "limit" | "balance" | "other";
  label: "Limit" | "Balance" | "Other";
  entries: ModelCatalogEntry[];
}

function parseBalanceValue(value: string): number | undefined {
  const parsed = Number.parseFloat(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

/**
 * Partition catalog entries into Limit/Balance/Other groups, classifying
 * per provider. Limit providers rank by their primary window's remaining
 * percent and balance providers by balance amount, both descending; ties
 * keep first-appearance order, provider entries stay adjacent and in
 * catalog order.
 */
export function quickPickGroups(entries: readonly ModelCatalogEntry[]): QuickPickGroup[] {
  const providerOrder: string[] = [];
  const entriesByProvider = new Map<string, ModelCatalogEntry[]>();
  for (const entry of entries) {
    const provider = entry.provider ?? "unknown";
    const bucket = entriesByProvider.get(provider);
    if (bucket === undefined) {
      entriesByProvider.set(provider, [entry]);
      providerOrder.push(provider);
    } else {
      bucket.push(entry);
    }
  }

  const limitGroups: { rank: number; entries: ModelCatalogEntry[] }[] = [];
  const balanceGroups: { rank: number; entries: ModelCatalogEntry[] }[] = [];
  const otherGroups: ModelCatalogEntry[][] = [];
  for (const provider of providerOrder) {
    const providerEntries = entriesByProvider.get(provider) ?? [];
    const readings = providerEntries.flatMap((entry) => entry.quotaReadings ?? []);
    const cls = classifyProviderQuota(readings);
    if (cls === undefined) {
      otherGroups.push(providerEntries);
    } else if (cls.kind === "limit") {
      limitGroups.push({ rank: cls.primaryLeftPercent, entries: providerEntries });
    } else {
      // Unparseable amounts rank below every parseable one (stable sort
      // keeps their relative first-appearance order).
      balanceGroups.push({
        rank: parseBalanceValue(cls.value) ?? Number.NEGATIVE_INFINITY,
        entries: providerEntries,
      });
    }
  }
  limitGroups.sort((a, b) => b.rank - a.rank);
  balanceGroups.sort((a, b) => b.rank - a.rank);
  // One group per kind; each kind concatenates its providers in ranked
  // order, so a provider's entries stay adjacent within the group.
  const groups: QuickPickGroup[] = [];
  if (limitGroups.length > 0) {
    groups.push({
      kind: "limit",
      label: "Limit",
      entries: limitGroups.flatMap(({ entries: groupEntries }) => groupEntries),
    });
  }
  if (balanceGroups.length > 0) {
    groups.push({
      kind: "balance",
      label: "Balance",
      entries: balanceGroups.flatMap(({ entries: groupEntries }) => groupEntries),
    });
  }
  if (otherGroups.length > 0) {
    groups.push({ kind: "other", label: "Other", entries: otherGroups.flat() });
  }
  return groups;
}

/** Human age of a quota reading: "45m ago", "2h ago", "3d ago". */
export function formatQuotaAge(fetchedAtMs: number, now: Date): string {
  const minutes = Math.floor(Math.max(0, now.getTime() - fetchedAtMs) / 60_000);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

/** Relative time until a quota window returns: "resets in 45m" / "2h" /
 * "3d". Past resets return "" so the segment can be omitted. */
export function formatQuotaReset(resetAtMs: number, now: Date): string {
  const minutes = Math.floor((resetAtMs - now.getTime()) / 60_000);
  if (minutes < 1) return "";
  if (minutes < 60) return `resets in ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `resets in ${hours}h`;
  return `resets in ${Math.floor(hours / 24)}d`;
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
 * ranked by provider quota, preselecting each group's first selectable
 * row; 5h-exhausted rows stay at the bottom of the Limit tab, disabled.
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
      for (const group of groups) {
        const rows = group.entries.map((entry) => ({
          entry,
          effortIndex: this.initialEffortIndex(entry),
          disabled: isQuotaExhausted(this.quotaClassByProvider.get(entry.provider ?? "unknown")),
        }));
        this.rowsByTab.set(group.label, rows);
        ordered.push(...rows);
        // The desc quota rank already sinks exhausted rows to the group's
        // bottom; the cursor starts on the first selectable row (0 when the
        // tab is entirely disabled). The `*` active marker stays as-is.
        const firstSelectable = rows.findIndex((row) => !row.disabled);
        const selected = firstSelectable < 0 ? 0 : firstSelectable;
        this.selectedByTab.set(group.label, selected);
        this.listsByTab.set(group.label, this.makeList(group.label, rows, selected));
      }
      // The default tab must offer a usable choice; Other rows are never
      // disabled, so a selectable tab always exists (0 as defense).
      this.activeTab = Math.max(
        0,
        this.tabs.findIndex((tab) => (this.rowsByTab.get(tab) ?? []).some((row) => !row.disabled)),
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
    // The keys above are consumed here, so the query input only receives
    // character data and edit chords (backspace, word deletes, undo). The
    // query is therefore append-only plus backspace for now.
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

  /** Description fallback for search rows: quota mode carries the active
   * group label, tabs mode keeps the legacy "All". */
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
