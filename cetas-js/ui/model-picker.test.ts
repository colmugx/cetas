import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import {
  ModelPickerOverlay,
  parseModelPickerOutcome,
} from "./model-picker.ts";

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

  test("rejects malformed catalog rather than showing a fake list", () => {
    expect(() =>
      parseModelPickerOutcome(
        JSON.stringify({
          type: "success",
          structured: [{ id: "broken", active: true }],
        }),
      ),
    ).toThrow("thinking_efforts");
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
