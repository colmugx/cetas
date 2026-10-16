/** Provider-neutral model command contract and strict boundary validation. */

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

