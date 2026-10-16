/** Pure quota analysis and ordering; no terminal dependencies. */
import type { ModelCatalogEntry, ProviderQuotaReading } from "./model-catalog.ts";

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
    // No 5h label: fall back to the most constrained window, keeping the
    // first reading on ties (covers exotic labels like kimi(<duration>)).
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

