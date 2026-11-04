import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import {
  formatPickCandidateNotices,
  formatQuotaAge,
  ModelPickerOverlay,
  parseModelPickerOutcome,
  type ModelCatalogEntry,
} from "./model-picker.ts";
import { theme } from "./theme.ts";

class FakeTui {
  shown?: Component;
  renders = 0;

  showOverlay(component: Component) {
    this.shown = component;
    return {
      hide: () => {},
      setHidden: () => {},
      isHidden: () => false,
      focus: () => {},
      unfocus: () => {},
      isFocused: () => true,
    };
  }

  requestRender(): void {
    this.renders++;
  }
}

describe("model picker contract", () => {
  test("parses provider-neutral slot catalog and effort values", () => {
    const parsed = parseModelPickerOutcome(
      JSON.stringify({
        type: "success",
        feedback: "Available model slots",
        structured: [
          {
            id: "kimi-code",
            label: "Kimi Code",
            provider: "kimi",
            model: "kimi-k2",
            active: true,
            active_effort: "high",
            thinking_efforts: ["low", "high"],
          },
        ],
      }),
    );
    expect(parsed.type).toBe("success");
    if (parsed.type !== "success") return;
    expect(parsed.entries[0]?.efforts).toEqual(["low", "high"]);
    expect(parsed.entries[0]?.activeEffort).toBe("high");
  });

  test("returns selected slot and effort from pi-tui list", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        {
          id: "slot-a",
          label: "Slot A",
          active: true,
          efforts: ["low", "high"],
        },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\u001b[C");
    tui.shown!.handleInput!("\r");
    expect(selected).toEqual({ slot: "slot-a", effort: "high" });
    expect(picker.isActive).toBe(false);
  });

  test("cycles provider tabs, preserves each tab cursor, and changes effort horizontally", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        {
          id: "p1-a",
          label: "Provider 1 A",
          provider: "provider-1",
          active: true,
          efforts: [],
        },
        {
          id: "p2-a",
          label: "Provider 2 A",
          provider: "provider-2",
          active: false,
          efforts: ["low", "high"],
        },
        {
          id: "p1-b",
          label: "Provider 1 B",
          provider: "provider-1",
          active: false,
          efforts: ["minimal"],
        },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    const panel = tui.shown!;
    // All starts on p1-a; move to p1-b, then switch to provider-1 tab and
    // back to All to prove each tab has an independent vertical cursor.
    panel.handleInput!("\u001b[B");
    panel.handleInput!("\t");
    panel.handleInput!("\u001b[Z");
    // Provider tab 1 restores its active p1-a cursor, then All restores p1-b.
    panel.handleInput!("\t");
    // All is active again; switch to provider-2 and cycle effort low→high.
    panel.handleInput!("\t");
    panel.handleInput!("\u001b[C");
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "p2-a", effort: "high" });
    expect(picker.isActive).toBe(false);
  });

  test("keeps the active provider visible when the tab strip is narrow", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(
      [
        { id: "a", label: "A", provider: "alpha", active: true, efforts: [] },
        { id: "b", label: "B", provider: "bravo", active: false, efforts: [] },
        { id: "c", label: "C", provider: "charlie", active: false, efforts: [] },
        { id: "d", label: "D", provider: "delta", active: false, efforts: [] },
      ],
      () => {},
      () => {},
    );
    const panel = tui.shown!;
    panel.handleInput!("\t");
    panel.handleInput!("\t");
    const rendered = panel.render(12).join("\n");
    expect(rendered).toContain("bravo");
    expect(rendered).toContain("<");
    expect(rendered).toContain(">");
  });

  test("groups provider-declared display groups into one tab", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        {
          id: "deepseek/deepseek-v4-flash",
          label: "DeepSeek / deepseek-v4-flash",
          provider: "deepseek",
          active: true,
          efforts: ["off", "high", "max"],
        },
        {
          id: "qwen/qwen3-coder",
          label: "qwen / qwen3-coder",
          provider: "qwen",
          group: "custom",
          active: false,
          efforts: [],
        },
        {
          id: "groq/llama-4",
          label: "groq / llama-4",
          provider: "groq",
          group: "custom",
          active: false,
          efforts: [],
        },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    const panel = tui.shown!;
    const activeProvider = () =>
      (panel as unknown as { activeProvider: string }).activeProvider;
    panel.handleInput!("\t");
    expect(activeProvider()).toBe("deepseek");
    panel.handleInput!("\t");
    expect(activeProvider()).toBe("custom");
    // The custom tab holds both providers; move down and select groq.
    panel.handleInput!("[B");
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "groq/llama-4" });
  });

  test("falls back to the provider-declared default effort for the initial highlight", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        {
          id: "qwen/qwen3-coder",
          label: "qwen / qwen3-coder",
          provider: "qwen",
          group: "custom",
          active: true,
          defaultEffort: "high",
          efforts: ["off", "low", "high"],
        },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    // No active_effort: the highlight starts on the declared default, not efforts[0].
    tui.shown!.handleInput!("\r");
    expect(selected).toEqual({ slot: "qwen/qwen3-coder", effort: "high" });
  });
});

describe("model picker search", () => {
  test("typing filters the catalog across provider tabs and hides the tab strip", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(
      [
        { id: "p1-alpha", label: "Alpha One", provider: "provider-1", active: true, efforts: [] },
        { id: "p1-beta", label: "Beta One", provider: "provider-1", active: false, efforts: [] },
        { id: "p2-gamma", label: "Gamma Two", provider: "provider-2", active: false, efforts: [] },
      ],
      () => {},
      () => {},
    );
    const panel = tui.shown!;
    // Search starts from the provider-1 tab and must still reach provider-2.
    panel.handleInput!("\t");
    panel.handleInput!("gamma");
    const lines = panel.render(60);
    expect(lines.some((line) => line.includes("Gamma Two"))).toBe(true);
    expect(lines.some((line) => line.includes("Alpha"))).toBe(false);
    expect(lines.some((line) => line.includes("Beta"))).toBe(false);
    expect(lines.some((line) => line.includes("> gamma"))).toBe(true);
    expect(lines.some((line) => line.includes("All"))).toBe(false);
    expect(picker.isActive).toBe(true);
  });

  test("multi-token queries narrow on label and provider together", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(
      [
        { id: "p1-alpha", label: "Alpha One", provider: "provider-1", active: true, efforts: [] },
        { id: "p1-beta", label: "Beta One", provider: "provider-1", active: false, efforts: [] },
        { id: "p2-gamma", label: "Gamma Two", provider: "provider-2", active: false, efforts: [] },
      ],
      () => {},
      () => {},
    );
    const panel = tui.shown!;
    panel.handleInput!("one provider-1");
    const lines = panel.render(60);
    expect(lines.some((line) => line.includes("Alpha One"))).toBe(true);
    expect(lines.some((line) => line.includes("Beta One"))).toBe(true);
    expect(lines.some((line) => line.includes("Gamma"))).toBe(false);
  });

  test("shows the match count with pluralization and a no-match line", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        { id: "a", label: "Swift", provider: "p1", active: true, efforts: [] },
        { id: "b", label: "Swifter", provider: "p2", active: false, efforts: [] },
      ],
      (value) => {
        selected = value;
      },
      () => {},
    );
    const panel = tui.shown!;
    panel.handleInput!("sw");
    expect(panel.render(60).some((line) => line.includes("2 matches"))).toBe(true);
    panel.handleInput!("ifter");
    expect(panel.render(60).some((line) => line.includes("1 match"))).toBe(true);
    expect(panel.render(60).some((line) => line.includes("2 matches"))).toBe(false);
    panel.handleInput!("z");
    const lines = panel.render(60);
    expect(lines.some((line) => line.includes("0 matches"))).toBe(true);
    expect(lines.some((line) => line.includes("No matching"))).toBe(true);
    // Enter over an empty result confirms nothing and keeps the picker open.
    panel.handleInput!("\r");
    expect(selected).toBeUndefined();
    expect(picker.isActive).toBe(true);
  });

  test("enter in search mode confirms the highlighted filtered entry", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        { id: "slot-a", label: "Slot A", provider: "p1", active: true, efforts: [] },
        { id: "slot-b", label: "Slot B", provider: "p2", active: false, efforts: ["low", "high"] },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    const panel = tui.shown!;
    panel.handleInput!("s");
    panel.handleInput!("\u001b[B");
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "slot-b", effort: "low" });
    expect(picker.isActive).toBe(false);
  });

  test("escape clears the query first and cancels only when the query is empty", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let cancelled = false;
    picker.open(
      [
        { id: "a", label: "Alpha", provider: "p1", active: true, efforts: [] },
        { id: "b", label: "Beta", provider: "p2", active: false, efforts: [] },
      ],
      () => {
        throw new Error("picker unexpectedly selected");
      },
      () => {
        cancelled = true;
      },
    );
    const panel = tui.shown!;
    panel.handleInput!("alph");
    expect(panel.render(40).some((line) => line.includes("> alph"))).toBe(true);
    panel.handleInput!("\u001b");
    const rendered = panel.render(40).join("\n");
    expect(rendered).toContain("All");
    expect(rendered.includes("> ")).toBe(false);
    expect(picker.isActive).toBe(true);
    panel.handleInput!("\u001b");
    expect(cancelled).toBe(true);
    expect(picker.isActive).toBe(false);
  });

  test("backspace shortens the query and widens the results", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(
      [
        { id: "a1", label: "Alpha One", provider: "p1", active: true, efforts: [] },
        { id: "a2", label: "Alpha Two", provider: "p2", active: false, efforts: [] },
        { id: "b1", label: "Beta", provider: "p1", active: false, efforts: [] },
      ],
      () => {},
      () => {},
    );
    const panel = tui.shown!;
    panel.handleInput!("alpha t");
    let lines = panel.render(60);
    expect(lines.some((line) => line.includes("1 match"))).toBe(true);
    expect(lines.some((line) => line.includes("Alpha One"))).toBe(false);
    expect(lines.some((line) => line.includes("Alpha Two"))).toBe(true);
    panel.handleInput!("\u007f");
    lines = panel.render(60);
    expect(lines.some((line) => line.includes("2 matches"))).toBe(true);
    expect(lines.some((line) => line.includes("Alpha One"))).toBe(true);
    expect(lines.some((line) => line.includes("Alpha Two"))).toBe(true);
  });

  test("left and right rotate the highlighted effort from search and persist after escape", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(
      [
        {
          id: "m1",
          label: "Mega",
          provider: "p1",
          active: true,
          efforts: ["low", "high", "max"],
        },
      ],
      () => {},
      () => {},
    );
    const panel = tui.shown!;
    panel.handleInput!("mega");
    expect(panel.render(60).join("\n")).toContain("effort: low");
    panel.handleInput!("\u001b[C");
    expect(panel.render(60).join("\n")).toContain("effort: high");
    panel.handleInput!("\u001b[C");
    expect(panel.render(60).join("\n")).toContain("effort: max");
    panel.handleInput!("\u001b[D");
    expect(panel.render(60).join("\n")).toContain("effort: high");
    // Leaving search must keep the rotation in the tabbed view.
    panel.handleInput!("\u001b");
    const rendered = panel.render(60).join("\n");
    expect(rendered).toContain("effort: high");
    expect(rendered).toContain("All");
  });
});

describe("model picker pricing badge", () => {
  const catalogWithPricing = (pricing: unknown) =>
    JSON.stringify({
      type: "success",
      structured: [
        {
          id: "deepseek/deepseek-v4-pro",
          label: "DeepSeek / deepseek-v4-pro",
          provider: "deepseek",
          model: "deepseek-v4-pro",
          active: true,
          thinking_efforts: [],
          pricing,
        },
      ],
    });

  test("only entries carrying pricing get a badge — GLM and kimi stay bare", () => {
    const parsed = parseModelPickerOutcome(
      JSON.stringify({
        type: "success",
        structured: [
          {
            id: "deepseek/deepseek-v4-pro",
            label: "DeepSeek / deepseek-v4-pro",
            provider: "deepseek",
            model: "deepseek-v4-pro",
            active: true,
            thinking_efforts: [],
            pricing: { tier: "peak", multiplier: "2x", window: "9:00 ~ 12:00, 14:00 ~ 18:00" },
          },
          {
            id: "zai-coding-plan/glm-5.3",
            label: "Z.ai Coding Plan / glm-5.3",
            provider: "zai-coding-plan",
            model: "glm-5.3",
            active: false,
            thinking_efforts: [],
          },
          {
            id: "kimi/kimi-k2",
            label: "Kimi Code",
            provider: "kimi",
            model: "kimi-k2",
            active: false,
            thinking_efforts: [],
          },
        ],
      }),
    );
    if (parsed.type !== "success") throw new Error("expected success");
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(parsed.entries, () => {}, () => {});
    const lines = tui.shown!.render(100);
    const lineOf = (label: string) => lines.find((line) => line.includes(label)) ?? "";
    expect(lineOf("DeepSeek / deepseek-v4-pro")).toContain(theme.red("2x"));
    expect(lineOf("Z.ai Coding Plan / glm-5.3")).not.toContain(theme.red("2x"));
    expect(lineOf("Z.ai Coding Plan / glm-5.3")).not.toContain("(");
    expect(lineOf("Kimi Code")).not.toContain("(");
    expect(lineOf("Kimi Code")).not.toContain(theme.success("1x"));
  });

  test("parses pricing from the payload; absent or null stays undefined", () => {
    const absent = parseModelPickerOutcome(
      JSON.stringify({
        type: "success",
        structured: [{ id: "a", label: "A", active: true, thinking_efforts: [] }],
      }),
    );
    if (absent.type !== "success") throw new Error("expected success");
    expect(absent.entries[0]?.pricing).toBeUndefined();
    const nulled = parseModelPickerOutcome(catalogWithPricing(null));
    if (nulled.type !== "success") throw new Error("expected success");
    expect(nulled.entries[0]?.pricing).toBeUndefined();
    const priced = parseModelPickerOutcome(
      catalogWithPricing({
        tier: "off-peak",
        multiplier: "1x",
        window: "9:00 ~ 12:00, 14:00 ~ 18:00",
      }),
    );
    if (priced.type !== "success") throw new Error("expected success");
    expect(priced.entries[0]?.pricing).toEqual({
      tier: "off-peak",
      multiplier: "1x",
      window: "9:00 ~ 12:00, 14:00 ~ 18:00",
    });
  });

  test("rejects malformed pricing", () => {
    expect(() =>
      parseModelPickerOutcome(
        catalogWithPricing({ tier: "weird", multiplier: "2x", window: "9:00 ~ 12:00" }),
      ),
    ).toThrow("tier");
    expect(() =>
      parseModelPickerOutcome(catalogWithPricing({ tier: "peak", window: "9:00 ~ 12:00" })),
    ).toThrow("multiplier");
    expect(() =>
      parseModelPickerOutcome(catalogWithPricing({ tier: "peak", multiplier: "2x" })),
    ).toThrow("window");
    expect(() => parseModelPickerOutcome(catalogWithPricing("nope"))).toThrow("must be an object");
  });
});

describe("model picker quota readings", () => {
  const catalogWithQuota = (quota_readings: unknown) =>
    JSON.stringify({
      type: "success",
      structured: [
        {
          id: "kimi-code",
          label: "Kimi Code",
          provider: "kimi",
          active: true,
          thinking_efforts: [],
          quota_readings,
        },
      ],
    });

  test("maps quota_readings onto typed entries with nulls preserved", () => {
    const parsed = parseModelPickerOutcome(
      catalogWithQuota([
        { window: "5h", used_percent: 10, available: true, reset_at_ms: 1234, fetched_at_ms: 1000 },
        { window: "balance", amount: { value: "4.20", currency: "USD" }, fetched_at_ms: 2000 },
      ]),
    );
    expect(parsed.type).toBe("success");
    if (parsed.type !== "success") return;
    const readings = parsed.entries[0]?.quotaReadings ?? [];
    expect(readings).toHaveLength(2);
    expect(readings[0]).toEqual({
      window: "5h",
      usedPercent: 10,
      amount: undefined,
      available: true,
      resetAtMs: 1234,
      fetchedAtMs: 1000,
    });
    expect(readings[1]?.amount).toEqual({ value: "4.20", currency: "USD" });
    expect(readings[1]?.usedPercent).toBeUndefined();
    // Explicit wire nulls stay null rather than collapsing to undefined.
    const nulled = parseModelPickerOutcome(
      catalogWithQuota([
        {
          window: "5h",
          used_percent: null,
          amount: null,
          available: null,
          reset_at_ms: null,
          fetched_at_ms: 5,
        },
      ]),
    );
    if (nulled.type !== "success") throw new Error("expected success");
    expect(nulled.entries[0]?.quotaReadings?.[0]).toEqual({
      window: "5h",
      usedPercent: null,
      amount: null,
      available: null,
      resetAtMs: null,
      fetchedAtMs: 5,
    });
  });

  test("entries without quota_readings keep it undefined", () => {
    const absent = parseModelPickerOutcome(
      JSON.stringify({
        type: "success",
        structured: [{ id: "a", label: "A", active: true, thinking_efforts: [] }],
      }),
    );
    if (absent.type !== "success") throw new Error("expected success");
    expect(absent.entries[0]?.quotaReadings).toBeUndefined();
    const nulled = parseModelPickerOutcome(catalogWithQuota(null));
    if (nulled.type !== "success") throw new Error("expected success");
    expect(nulled.entries[0]?.quotaReadings).toBeUndefined();
  });

  test("rejects malformed quota readings", () => {
    expect(() =>
      parseModelPickerOutcome(
        catalogWithQuota([{ window: "5h", used_percent: "90", fetched_at_ms: 1 }]),
      ),
    ).toThrow("used_percent");
    expect(() =>
      parseModelPickerOutcome(catalogWithQuota([{ window: "5h", fetched_at_ms: "soon" }])),
    ).toThrow("fetched_at_ms");
    expect(() =>
      parseModelPickerOutcome(catalogWithQuota([{ fetched_at_ms: 1 }])),
    ).toThrow("window");
    expect(() => parseModelPickerOutcome(catalogWithQuota("nope"))).toThrow("must be an array");
    expect(() =>
      parseModelPickerOutcome(
        catalogWithQuota([{ window: "5h", fetched_at_ms: 1, amount: { value: 1, currency: "USD" } }]),
      ),
    ).toThrow("amount.value");
  });
});

describe("model picker quota mode", () => {
  const epoch = () => new Date(0);
  const quotaEntries: ModelCatalogEntry[] = [
    {
      id: "bravo-a",
      label: "Bravo",
      provider: "bravo",
      active: true,
      efforts: [],
      // Weekly-rich but only 5h 60 left: the weekly window never enters the rank.
      quotaReadings: [
        { window: "5h", usedPercent: 40, fetchedAtMs: 0 },
        { window: "weekly", usedPercent: 5, fetchedAtMs: 0 },
      ],
    },
    {
      id: "alpha-a",
      label: "Alpha",
      provider: "alpha",
      active: false,
      efforts: [],
      quotaReadings: [
        { window: "5h", usedPercent: 10, fetchedAtMs: 0 },
        { window: "weekly", usedPercent: 50, fetchedAtMs: 0 },
      ],
    },
    {
      id: "charlie-a",
      label: "Charlie",
      provider: "charlie",
      active: false,
      efforts: [],
      quotaReadings: [
        { window: "balance", amount: { value: "12.5", currency: "USD" }, fetchedAtMs: 0 },
      ],
    },
    { id: "delta-a", label: "Delta", provider: "delta", active: false, efforts: [] },
  ];
  const activeTabOf = (panel: Component): string =>
    (panel as unknown as { activeProvider: string }).activeProvider;

  test("limits tab leads and Enter immediately picks the active entry", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      quotaEntries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    expect(activeTabOf(panel)).toBe("Limit");
    const rendered = panel.render(100).join("\n");
    expect(rendered).toContain("Limit");
    expect(rendered).toContain("Balance");
    expect(rendered).toContain("Other");
    // No arrows: Enter confirms the selectable active entry (bravo-a), even
    // though alpha ranks higher on 5h remaining — quota mode prefers the
    // active selection over the first selectable row.
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "bravo-a" });
    expect(picker.isActive).toBe(false);
  });

  test("quota mode preselects the selectable active entry and defaults to its group", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "alpha-a",
        label: "Alpha",
        provider: "alpha",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 10, fetchedAtMs: 0 }], // 90 left: ranks first
      },
      {
        id: "charlie-a",
        label: "Charlie",
        provider: "charlie",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "balance", amount: { value: "12.5", currency: "USD" }, fetchedAtMs: 0 },
        ],
      },
      {
        id: "charlie-b",
        label: "Charlie B",
        provider: "charlie",
        active: true,
        efforts: [],
        quotaReadings: [
          { window: "balance", amount: { value: "12.5", currency: "USD" }, fetchedAtMs: 0 },
        ],
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      entries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    // The default tab follows the selectable active entry, not the
    // top-ranked Limit group.
    expect(activeTabOf(panel)).toBe("Balance");
    // Enter immediately confirms the active entry even though an inactive
    // balance row comes first in the group.
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "charlie-b" });
    expect(picker.isActive).toBe(false);
  });

  test("an exhausted active entry falls back to the first selectable row", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "alive-a",
        label: "Alive",
        provider: "alive",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 50, fetchedAtMs: 0 }], // 50 left
      },
      {
        id: "gone-a",
        label: "Gone",
        provider: "gone",
        active: true,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: 0 }], // 0 left
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      entries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    // The exhausted active entry cannot take the cursor; Limit rows rank
    // [Alive, Gone], so the first selectable row does.
    expect(activeTabOf(panel)).toBe("Limit");
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "alive-a" });
    expect(picker.isActive).toBe(false);
  });

  test("a group with no active entry keeps the first-selectable cursor", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "alpha-a",
        label: "Alpha",
        provider: "alpha",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 10, fetchedAtMs: 0 }], // 90 left
      },
      {
        id: "alpha-b",
        label: "Alpha B",
        provider: "alpha",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 10, fetchedAtMs: 0 }],
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      entries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    expect(activeTabOf(panel)).toBe("Limit");
    // No active entry anywhere: Enter confirms the top-ranked (first
    // selectable) row as before.
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "alpha-a" });
    expect(picker.isActive).toBe(false);
  });

  test("tab strip cycles groups in quota order and each group starts at row 0", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    const picks: unknown[] = [];
    picker.open(
      quotaEntries,
      (value) => {
        picks.push(value);
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    panel.handleInput!("\t");
    expect(activeTabOf(panel)).toBe("Balance");
    panel.handleInput!("\r");
    expect(picks).toEqual([{ slot: "charlie-a" }]);
    picker.open(
      quotaEntries,
      (value) => {
        picks.push(value);
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    const otherPanel = tui.shown!;
    otherPanel.handleInput!("\t");
    otherPanel.handleInput!("\t");
    expect(activeTabOf(otherPanel)).toBe("Other");
    otherPanel.handleInput!("\r");
    expect(picks).toEqual([{ slot: "charlie-a" }, { slot: "delta-a" }]);
  });

  test("rows show colored left badges, plain balances, n/a, and staleness", () => {
    const fetchedAt = Date.UTC(2026, 8, 9, 12, 0, 0);
    const entries: ModelCatalogEntry[] = [
      {
        id: "alpha-a",
        label: "Alpha",
        provider: "alpha",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "5h", usedPercent: 10, fetchedAtMs: fetchedAt },
          { window: "weekly", usedPercent: 50, fetchedAtMs: fetchedAt },
        ],
      },
      {
        id: "dead-weekly-a",
        label: "DeadWeekly",
        provider: "dead-weekly",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "5h", usedPercent: 10, fetchedAtMs: fetchedAt },
          { window: "weekly", usedPercent: 100, fetchedAtMs: fetchedAt },
        ],
      },
      {
        id: "mid-a",
        label: "Mid",
        provider: "mid",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 40, fetchedAtMs: fetchedAt }],
      },
      {
        id: "warm-a",
        label: "Warm",
        provider: "warm",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "daily", usedPercent: 85, fetchedAtMs: fetchedAt }],
      },
      {
        id: "zero-a",
        label: "Zero",
        provider: "zero",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "daily", usedPercent: 100, fetchedAtMs: fetchedAt }],
      },
      {
        id: "charlie-a",
        label: "Charlie",
        provider: "charlie",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "balance", amount: { value: "12.5", currency: "USD" }, fetchedAtMs: fetchedAt },
        ],
      },
      { id: "delta-a", label: "Delta", provider: "delta", active: false, efforts: [] },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(entries, () => {}, () => {}, () => new Date(fetchedAt), "quota");
    const panel = tui.shown!;
    const lineOf = (label: string, source: string[]) =>
      source.find((line) => line.includes(label)) ?? "";
    const lines = panel.render(160);
    expect(lineOf("Alpha", lines)).toContain("5h 90% left");
    expect(lineOf("Alpha", lines)).toContain(theme.muted("90% left"));
    expect(lineOf("Alpha", lines)).toContain(theme.muted(" · weekly 50"));
    // Weekly-exhausted DeadWeekly reads with the worst-window error color
    // yet still ranks above Mid's healthier 5h window.
    expect(lineOf("DeadWeekly", lines)).toContain(theme.error("90% left"));
    expect(lineOf("DeadWeekly", lines)).toContain(theme.muted(" · weekly 0"));
    const indexOfLabel = (label: string) => lines.findIndex((line) => line.includes(label));
    expect(indexOfLabel("DeadWeekly")).toBeGreaterThanOrEqual(0);
    expect(indexOfLabel("DeadWeekly")).toBeLessThan(indexOfLabel("Mid"));
    expect(lineOf("Mid", lines)).toContain(theme.muted("60% left"));
    expect(lineOf("Warm", lines)).toContain(theme.warning("15% left"));
    expect(lineOf("Zero", lines)).toContain(theme.error("0% left"));
    expect(lineOf("Alpha", lines)).not.toContain("ago");

    // The balance and n/a rows live on their own tabs.
    panel.handleInput!("\t");
    const balanceLines = panel.render(160);
    expect(lineOf("Charlie", balanceLines)).toContain("12.5 USD");
    panel.handleInput!("\t");
    const otherLines = panel.render(160);
    expect(lineOf("Delta", otherLines)).toContain(theme.muted("n/a"));

    picker.hide();
    const staleNow = () => new Date(fetchedAt + 2 * 60 * 60 * 1000);
    picker.open(entries, () => {}, () => {}, staleNow, "quota");
    const staleLines = tui.shown!.render(160);
    const alphaLine = lineOf("Alpha", staleLines);
    expect(alphaLine).toContain("2h ago");
    expect(alphaLine).toContain(theme.muted(formatQuotaAge(fetchedAt, staleNow())));
  });

  test("default tabs mode keeps display_group grouping and active preselect without quota data", () => {
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    picker.open(
      [
        { id: "custom-a", label: "Custom A", provider: "p1", group: "custom", active: false, efforts: [] },
        { id: "alpha-idle", label: "Alpha Idle", provider: "alpha", active: false, efforts: [] },
        { id: "alpha-live", label: "Alpha Live", provider: "alpha", active: true, efforts: ["low"] },
      ],
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
    );
    const panel = tui.shown!;
    expect(activeTabOf(panel)).toBe("All");
    panel.handleInput!("\t");
    expect(activeTabOf(panel)).toBe("custom");
    panel.handleInput!("\t");
    expect(activeTabOf(panel)).toBe("alpha");
    // The active row is preselected even though an inactive row comes first.
    panel.handleInput!("\r");
    expect(selected).toEqual({ slot: "alpha-live", effort: "low" });
    expect(picker.isActive).toBe(false);
  });

  test("up/down navigation skips 5h-exhausted rows", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "alpha-a",
        label: "Alpha",
        provider: "alpha",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 50, fetchedAtMs: 0 }], // 50 left
      },
      {
        id: "bravo-a",
        label: "Bravo",
        provider: "bravo",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 20, fetchedAtMs: 0 }], // 80 left
      },
      {
        id: "gone-a",
        label: "Gone",
        provider: "gone",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: 0 }], // 0 left
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selected: unknown;
    // Limit rows are [bravo, alpha, gone]; three downs walk 0 -> 1 -> 0 -> 1
    // because the exhausted row is never landed on.
    picker.open(
      entries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    expect(selected).toEqual({ slot: "alpha-a" });
    // Up from the top wraps past the exhausted row onto alpha.
    picker.open(
      entries,
      (value) => {
        selected = value;
      },
      () => {
        throw new Error("picker unexpectedly cancelled");
      },
      epoch,
      "quota",
    );
    tui.shown!.handleInput!("\u001b[A");
    tui.shown!.handleInput!("\r");
    expect(selected).toEqual({ slot: "alpha-a" });
  });

  test("an all-disabled Limit tab never confirms and the default tab moves to a selectable group", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "gone-a",
        label: "Gone A",
        provider: "gone",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: 0 }],
      },
      {
        id: "gone-b",
        label: "Gone B",
        provider: "gone",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: 0 }],
      },
      {
        id: "charlie-a",
        label: "Charlie",
        provider: "charlie",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "balance", amount: { value: "12.5", currency: "USD" }, fetchedAtMs: 0 },
        ],
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    let selections = 0;
    let cancellations = 0;
    picker.open(
      entries,
      () => {
        selections += 1;
      },
      () => {
        cancellations += 1;
      },
      epoch,
      "quota",
    );
    const panel = tui.shown!;
    // The all-exhausted Limit tab cannot be the default.
    expect(activeTabOf(panel)).toBe("Balance");
    panel.handleInput!("\t"); // back onto the all-disabled Limit tab
    expect(activeTabOf(panel)).toBe("Limit");
    panel.handleInput!("\u001b[B");
    panel.handleInput!("\u001b[A");
    panel.handleInput!("\r");
    expect(selections).toBe(0);
    expect(cancellations).toBe(0);
    expect(picker.isActive).toBe(true);
    // The cursor never moved: the selection arrow stays on row 0.
    const lines = panel.render(80);
    expect(lines.some((line) => line.startsWith("→   Gone A"))).toBe(true);
    expect(lines.some((line) => line.startsWith("→   Gone B"))).toBe(false);
  });

  test("quota-mode fuzzy search excludes disabled rows", () => {
    const entries: ModelCatalogEntry[] = [
      {
        id: "alive-a",
        label: "Alive",
        provider: "alive",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 50, fetchedAtMs: 0 }],
      },
      {
        id: "gone-a",
        label: "Gone",
        provider: "gone",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: 0 }],
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(entries, () => {}, () => {}, epoch, "quota");
    const panel = tui.shown!;
    panel.handleInput!("gone");
    let lines = panel.render(60);
    expect(lines.some((line) => line.includes("Gone"))).toBe(false);
    expect(lines.some((line) => line.includes("0 matches"))).toBe(true);
    panel.handleInput!("\u001b"); // clears the query
    panel.handleInput!("alive");
    lines = panel.render(60);
    expect(lines.some((line) => line.includes("Alive"))).toBe(true);
    expect(lines.some((line) => line.includes("1 match"))).toBe(true);
  });

  test("disabled rows render muted with a reset countdown; selectable rows stay plain", () => {
    const now = Date.UTC(2026, 8, 10, 12, 0, 0);
    const twoHours = 2 * 60 * 60 * 1000;
    const entries: ModelCatalogEntry[] = [
      {
        id: "gone-a",
        label: "Gone",
        provider: "gone",
        active: false,
        efforts: ["high"],
        quotaReadings: [
          { window: "5h", usedPercent: 100, fetchedAtMs: now, resetAtMs: now + twoHours },
        ],
      },
      {
        id: "bare-a",
        label: "Bare",
        provider: "bare",
        active: false,
        efforts: [],
        quotaReadings: [{ window: "5h", usedPercent: 100, fetchedAtMs: now }],
      },
      {
        id: "alive-a",
        label: "Alive",
        provider: "alive",
        active: false,
        efforts: [],
        quotaReadings: [
          { window: "5h", usedPercent: 50, fetchedAtMs: now, resetAtMs: now + twoHours },
        ],
      },
    ];
    const tui = new FakeTui();
    const picker = new ModelPickerOverlay(tui as never);
    picker.open(entries, () => {}, () => {}, () => new Date(now), "quota");
    const lines = tui.shown!.render(160);
    const lineOf = (label: string) => lines.find((line) => line.includes(label)) ?? "";
    const goneLine = lineOf("Gone");
    expect(goneLine).toContain(theme.muted("  Gone"));
    expect(goneLine).toContain(theme.muted(" resets in 2h"));
    expect(goneLine).toContain(theme.muted(" · effort: high"));
    // The badge pipeline is untouched, so the exhausted severity stays red.
    expect(goneLine).toContain(theme.error("0% left"));
    // Disabled without a reset time renders no countdown.
    expect(lineOf("Bare")).not.toContain("resets in");
    const aliveLine = lineOf("Alive");
    expect(aliveLine).toContain(theme.muted("50% left"));
    expect(aliveLine).not.toContain("resets in");
  });
});

describe("model picker candidate notices", () => {
  const pickOutcome = (candidates: unknown) => ({
    provider: "openai",
    picked: {
      slot_id: "openai/gpt-6-astra",
      model: "gpt-6-astra",
      effort: "medium",
      iq: 107.48,
      cost_usd: 2.262258,
    },
    candidates,
  });

  test("formats both runner-ups as candidate 2 and 3 with fixed precision", () => {
    expect(
      formatPickCandidateNotices(
        pickOutcome([
          {
            slot_id: "openai/gpt-6-astra",
            model: "gpt-6-astra",
            effort: "medium",
            iq: 107.48,
            cost_usd: 2.262258,
          },
          {
            slot_id: "deepseek/deepseek-v4-flash",
            model: "deepseek-v4-flash",
            effort: "max",
            iq: 85.71,
            cost_usd: 0.224375,
          },
        ]),
      ),
    ).toEqual([
      "candidate 2 — gpt-6-astra:medium · IQ 107.5 · $2.26",
      "candidate 3 — deepseek-v4-flash:max · IQ 85.7 · $0.22",
    ]);
  });

  test("outcomes without candidates, or with null ones, render no notices", () => {
    expect(formatPickCandidateNotices({ provider: "openai" })).toEqual([]);
    expect(formatPickCandidateNotices(pickOutcome(null))).toEqual([]);
  });

  test("rejects malformed candidate entries", () => {
    expect(() =>
      formatPickCandidateNotices(
        pickOutcome([{ slot_id: "s", effort: "high", iq: 115.0, cost_usd: 4.0 }]),
      ),
    ).toThrow("model");
    expect(() =>
      formatPickCandidateNotices(
        pickOutcome([{ slot_id: "s", model: "", effort: "high", iq: 115.0, cost_usd: 4.0 }]),
      ),
    ).toThrow("non-empty");
    expect(() =>
      formatPickCandidateNotices(
        pickOutcome([{ slot_id: "s", model: "m", effort: "high", iq: "115", cost_usd: 4.0 }]),
      ),
    ).toThrow("iq");
    expect(() =>
      formatPickCandidateNotices(
        pickOutcome([{ slot_id: "s", model: "m", effort: "high", iq: 115.0, cost_usd: "4" }]),
      ),
    ).toThrow("cost_usd");
    expect(() =>
      formatPickCandidateNotices(
        pickOutcome([{ model: "m", effort: "high", iq: 115.0, cost_usd: 4.0 }]),
      ),
    ).toThrow("slot_id");
    expect(() => formatPickCandidateNotices(pickOutcome("nope"))).toThrow("must be an array");
  });
});
