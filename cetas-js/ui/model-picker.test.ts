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
});
