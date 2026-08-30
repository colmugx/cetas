import { describe, expect, test } from "bun:test";

import { formatPricingBadge, pricingPhaseFor } from "./pricing-phase.ts";

// 2026-08-28 is a Friday. Instants are UTC; the rules read Beijing time.
const friday = (hour: number, minute = 0) => new Date(Date.UTC(2026, 7, 28, hour, minute));
const saturday = (hour: number) => new Date(Date.UTC(2026, 7, 29, hour));

describe("pricing phase rules", () => {
  test("deepseek peak covers both weekday windows with inclusive starts", () => {
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(1))?.tier).toBe("peak"); // 9:00 Beijing
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(4))?.tier).toBe("off-peak"); // 12:00 lunch
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(6, 30))?.tier).toBe("peak"); // 14:30
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(10))?.tier).toBe("off-peak"); // 18:00
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(0, 30))?.tier).toBe("off-peak"); // 8:30
  });

  test("zai-coding-plan peak is weekday 14:00-18:00 Beijing only", () => {
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", friday(5, 59))?.tier).toBe("off-peak"); // 13:59
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", friday(6))?.tier).toBe("peak"); // 14:00
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", friday(10))?.tier).toBe("off-peak"); // 18:00
  });

  test("weekends are off-peak all day for both providers", () => {
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", saturday(2))?.tier).toBe("off-peak"); // 10:00 Sat
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", saturday(8))?.tier).toBe("off-peak"); // 16:00 Sat
  });

  test("deepseek multipliers double at peak and carry the peak window text", () => {
    const peak = pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(2));
    expect(peak?.multiplier).toBe("2x");
    expect(peak?.window).toBe("9:00 ~ 12:00, 14:00 ~ 18:00");
    expect(pricingPhaseFor("deepseek", "deepseek-v4-pro", friday(12))?.multiplier).toBe("1x");
  });

  test("zai-coding-plan multipliers default to 3x/1x; glm-5.3-flash overrides to 1.2x/0.4x", () => {
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", friday(8))?.multiplier).toBe("3x");
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3", friday(0))?.multiplier).toBe("1x");
    expect(pricingPhaseFor("zai-coding-plan", undefined, friday(8))?.multiplier).toBe("3x");
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3-flash", friday(8))?.multiplier).toBe("1.2x");
    expect(pricingPhaseFor("zai-coding-plan", "glm-5.3-flash", friday(0))?.multiplier).toBe("0.4x");
  });

  test("unknown providers get no phase or badge", () => {
    expect(pricingPhaseFor("kimi", "kimi-k2", friday(8))).toBeUndefined();
    expect(pricingPhaseFor(undefined, "kimi-k2", friday(8))).toBeUndefined();
    expect(formatPricingBadge("kimi", "kimi-k2", friday(8))).toBe("");
    expect(formatPricingBadge(undefined, undefined, friday(8))).toBe("");
  });

  test("peak badge carries the window; off-peak shows the multiplier only", () => {
    const peak = formatPricingBadge("zai-coding-plan", "glm-5.3", friday(8));
    expect(peak).toContain("3x");
    expect(peak).toContain("(14:00 ~ 18:00)");
    const offPeak = formatPricingBadge("zai-coding-plan", "glm-5.3", friday(0)); // 8:00 Beijing
    expect(offPeak).toContain("1x");
    expect(offPeak).not.toContain("(");
  });
});
