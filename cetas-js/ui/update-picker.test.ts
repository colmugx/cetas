import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import { UpdateOverlay, type UpdateChoice } from "./update-picker.ts";

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

function openUpdateOverlay(): {
  tui: FakeTui;
  state: { choices: UpdateChoice[]; closed: number };
} {
  const tui = new FakeTui();
  const overlay = new UpdateOverlay(tui as never);
  const state = { choices: [] as UpdateChoice[], closed: 0 };
  overlay.open(
    "0.8.1",
    "0.9.1",
    "bun add -g @posoco/cetas@latest",
    (choice) => state.choices.push(choice),
    () => {
      state.closed++;
    },
  );
  return { tui, state };
}

describe("update picker contract", () => {
  test("renders the version span and the manager-specific command", () => {
    const { tui } = openUpdateOverlay();
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("0.8.1");
    expect(rendered).toContain("0.9.1");
    expect(rendered).toContain("bun add -g @posoco/cetas@latest");
    expect(rendered).toContain("Show command");
    expect(rendered).toContain("Skip");
  });

  test("enter on the highlighted row picks Update now", () => {
    const { tui, state } = openUpdateOverlay();
    tui.shown!.handleInput!("\r");
    expect(state.choices).toEqual(["update"]);
    expect(state.closed).toBe(1);
    expect(tui.renders).toBeGreaterThan(0);
  });

  test("arrow down once picks Show command; twice picks Skip", () => {
    const first = openUpdateOverlay();
    first.tui.shown!.handleInput!("\u001b[B");
    first.tui.shown!.handleInput!("\r");
    expect(first.state.choices).toEqual(["command"]);

    const second = openUpdateOverlay();
    second.tui.shown!.handleInput!("\u001b[B");
    second.tui.shown!.handleInput!("\u001b[B");
    second.tui.shown!.handleInput!("\r");
    expect(second.state.choices).toEqual(["skip"]);
  });

  test("escape and q close without choosing", () => {
    for (const key of ["\u001b", "q"]) {
      const { tui, state } = openUpdateOverlay();
      tui.shown!.handleInput!(key);
      expect(state.choices).toEqual([]);
      expect(state.closed).toBe(1);
      expect(tui.shown).toBeDefined();
    }
  });
});
