import { stripTerminalSequences } from "@earendil-works/pi-tui";
import type { ModelCatalogEntry } from "./model-picker.ts";

const clean = (value: unknown): string => typeof value === "string"
  ? stripTerminalSequences(value).replace(/[\\u0000-\\u001F\\u007F]/g, "").slice(0, 90)
  : "";

/** Pure view projection: neither command execution nor overlay ownership belongs here. */
export function formatQuotaLines(raw: unknown, models?: readonly ModelCatalogEntry[]): string[] {
  const lines = ["Quotas", "Use /quota refresh to request updated Gateway quota cards."];
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return lines;
  const record = raw as Record<string, unknown>;
  if (record.manager === "providers") {
    if (models === undefined) return [...lines, "Provider quota data unavailable."];
    const providers = new Map<string, string[]>();
    for (const entry of models) {
      const id = clean(entry.provider ?? "Unknown provider");
      if (providers.has(id)) continue;
      const readings = entry.quotaReadings ?? [];
      const rows = readings.map((q) => {
        const quantity = q.usedPercent == null
          ? q.amount == null ? "Unknown" : `${q.amount.value} ${q.amount.currency}`
          : `${q.usedPercent}% used`;
        return `  ${clean(q.window)}: ${clean(quantity)}`;
      });
      providers.set(id, rows.length > 0 ? rows : ["  Quota unavailable"]);
    }
    for (const [provider, rows] of providers) lines.push(provider, ...rows.slice(0, 20));
    return lines;
  }
  if (!Array.isArray(record.cards)) return lines;
  for (const rawCard of record.cards.slice(0, 100)) {
    if (typeof rawCard !== "object" || rawCard === null || Array.isArray(rawCard)) continue;
    const card = rawCard as Record<string, unknown>;
    const label = [clean(card.provider), clean(card.name), clean(card.plan)].filter(Boolean).join(" · ");
    lines.push(label || "Unknown provider");
    if (card.error) lines.push("  Unavailable");
    if (card.read_at) lines.push(`  snapshot: ${clean(card.read_at)}`);
    if (!Array.isArray(card.windows)) continue;
    for (const rawWindow of card.windows.slice(0, 20)) {
      if (typeof rawWindow !== "object" || rawWindow === null || Array.isArray(rawWindow)) continue;
      const window = rawWindow as Record<string, unknown>;
      const remaining = typeof window.remaining === "number" && Number.isFinite(window.remaining)
        ? `${window.remaining}% remaining` : "";
      const amount = typeof window.amount === "number" && typeof window.limit === "number"
        ? `${window.amount} / ${window.limit}` : "";
      lines.push(`  ${clean(window.name)}: ${clean(window.display) || remaining || amount || "Unknown"}`);
      if (typeof window.resets_at === "string") lines.push(`  reset: ${clean(window.resets_at)}`);
    }
  }
  if (record.cards.length === 0) lines.push("No accessible quota cards.");
  return lines;
}
