/**
 * Peak/off-peak pricing badge for the model picker.
 *
 * DeepSeek and Z.ai both define peak windows in Beijing time (UTC+8) on
 * weekdays only; everything outside them bills at the off-peak rate. Both
 * vendors bill by weekday, so holidays are not modeled either. When a plan
 * changes its multipliers or windows, edit PRICING_RULES — nothing else.
 */

import { theme } from "./theme.ts";

interface ModelMultiplier {
  peak: string;
  offPeak: string;
}

interface PricingRule {
  /** Peak windows as [start, end) minutes past Beijing midnight. */
  windows: readonly (readonly [number, number])[];
  weekdayOnly: boolean;
  peakMultiplier: string;
  offPeakMultiplier: string;
  /** Per-model multipliers overriding the provider defaults (exact id match). */
  modelMultipliers?: Record<string, ModelMultiplier>;
  /** Peak window text shown in the badge parentheses. */
  windowText: string;
}

const PRICING_RULES: Record<string, PricingRule> = {
  deepseek: {
    windows: [[540, 720], [840, 1080]],
    weekdayOnly: true,
    peakMultiplier: "2x",
    offPeakMultiplier: "1x",
    windowText: "9:00 ~ 12:00, 14:00 ~ 18:00",
  },
  "zai-coding-plan": {
    windows: [[840, 1080]],
    weekdayOnly: true,
    peakMultiplier: "3x",
    offPeakMultiplier: "1x",
    modelMultipliers: {
      "glm-5.3-flash": { peak: "1.2x", offPeak: "0.4x" },
    },
    windowText: "14:00 ~ 18:00",
  },
};

export interface PricingPhase {
  tier: "peak" | "off-peak";
  multiplier: string;
  window: string;
}

/** Beijing wall clock has no DST, so a fixed +8h shift of UTC is exact. */
function beijingWallClock(now: Date): { weekday: number; minutes: number } {
  const shifted = new Date(now.getTime() + 8 * 60 * 60 * 1000);
  return {
    weekday: shifted.getUTCDay(),
    minutes: shifted.getUTCHours() * 60 + shifted.getUTCMinutes(),
  };
}

function isPeak(rule: PricingRule, now: Date): boolean {
  const { weekday, minutes } = beijingWallClock(now);
  if (rule.weekdayOnly && (weekday === 0 || weekday === 6)) return false;
  return rule.windows.some(([start, end]) => minutes >= start && minutes < end);
}

export function pricingPhaseFor(
  provider: string | undefined,
  model: string | undefined,
  now: Date,
): PricingPhase | undefined {
  if (provider === undefined) return undefined;
  const rule = PRICING_RULES[provider] as PricingRule | undefined;
  if (rule === undefined) return undefined;
  const peak = isPeak(rule, now);
  const multipliers =
    (model !== undefined ? rule.modelMultipliers?.[model] : undefined) ??
    ({ peak: rule.peakMultiplier, offPeak: rule.offPeakMultiplier } satisfies ModelMultiplier);
  return {
    tier: peak ? "peak" : "off-peak",
    multiplier: peak ? multipliers.peak : multipliers.offPeak,
    window: rule.windowText,
  };
}

/**
 * Picker-row pricing badge. Peak: red multiplier plus a dim parenthesized
 * window naming the surcharge period. Off-peak: green multiplier only.
 */
export function formatPricingBadge(
  provider: string | undefined,
  model: string | undefined,
  now: Date,
): string {
  const phase = pricingPhaseFor(provider, model, now);
  if (phase === undefined) return "";
  if (phase.tier === "peak") {
    return ` ${theme.red(phase.multiplier)} ${theme.dim(`(${phase.window})`)}`;
  }
  return ` ${theme.success(phase.multiplier)}`;
}
