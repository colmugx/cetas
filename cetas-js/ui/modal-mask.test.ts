import { describe, expect, test } from "bun:test";
import chalk from "chalk";

import {
  ModalVeilHost,
  dimLine,
  type VeilTui,
} from "./modal-mask.ts";
import type { Component, OverlayOptions } from "@earendil-works/pi-tui";

interface ShownOverlay {
  component: Component;
  options?: OverlayOptions;
  hidden: boolean;
}

class FakeVeilTui implements VeilTui {
  readonly terminal = { rows: 6, columns: 40 };
  readonly overlays: ShownOverlay[] = [];
  renderCalls = 0;

  constructor(private readonly baseLines: string[] = []) {}

  render(width: number): string[] {
    this.renderCalls += 1;
    return this.baseLines.map((line) => line);
  }

  showOverlay(component: Component, options?: OverlayOptions) {
    const entry: ShownOverlay = { component, options, hidden: false };
    this.overlays.push(entry);
    return {
      hide: () => {
        entry.hidden = true;
      },
      setHidden: (hidden: boolean) => {
        entry.hidden = hidden;
      },
      isHidden: () => entry.hidden,
      focus: () => {},
      unfocus: () => {},
      isFocused: () => false,
      getBounds: () => undefined,
    };
  }

  requestRender(): void {}
}

function panel(): Component {
  return {
    render: () => ["panel"],
    invalidate: () => {},
  };
}

describe("dimLine", () => {
  test("flattens ANSI/OSC escapes into faint gray text", () => {
    chalk.level = 3;
    const dimmed = dimLine("\u001b[31mred\u001b[0m plain \u001b]8;;http://x\u0007link\u001b]8;;\u0007");
    expect(dimmed).toContain("red plain link");
    expect(dimmed).not.toContain("31");
    expect(dimmed).not.toContain("]8;;");
    expect(dimmed).toContain("\u001b[2m");
  });

  test("blank content stays blank", () => {
    expect(dimLine("   ")).toBe("");
    expect(dimLine("")).toBe("");
  });
});

describe("ModalVeilHost", () => {
  test("shows a non-capturing full-width veil below the modal", () => {
    const tui = new FakeVeilTui(["hello"]);
    const host = new ModalVeilHost(tui);
    host.showOverlay(panel(), { width: "76%", anchor: "center" });

    expect(tui.overlays).toHaveLength(2);
    const [veil, modal] = tui.overlays;
    expect(veil!.options?.nonCapturing).toBe(true);
    expect(veil!.options?.width).toBe("100%");
    expect(veil!.options?.anchor).toBe("top-left");
    expect(modal!.options?.width).toBe("76%");
  });

  test("the veil renders the visible viewport of the base, dimmed", () => {
    const base = ["\u001b[32mgreen row\u001b[0m", "", "third"];
    const tui = new FakeVeilTui(base);
    const host = new ModalVeilHost(tui);
    host.showOverlay(panel());

    const veil = tui.overlays[0]!;
    const lines = veil.component.render(tui.terminal.columns);
    expect(lines).toHaveLength(tui.terminal.rows);
    expect(lines[0]).toContain("green row");
    expect(lines[0]).toContain("\u001b[2m");
    expect(lines[1]).toBe("");
    expect(lines[2]).toContain("third");
    // The veil re-derives the base content each render cycle.
    expect(tui.renderCalls).toBeGreaterThan(0);
  });

  test("keeps the veil until the last modal handle hides", () => {
    const tui = new FakeVeilTui(["a"]);
    const host = new ModalVeilHost(tui);
    const first = host.showOverlay(panel());
    const second = host.showOverlay(panel());
    expect(tui.overlays).toHaveLength(3);

    first.hide();
    expect(tui.overlays[0]!.hidden).toBe(false);

    second.hide();
    expect(tui.overlays[0]!.hidden).toBe(true);
  });

  test("a veil hidden with the modal is not re-created by stale handles", () => {
    const tui = new FakeVeilTui(["a"]);
    const host = new ModalVeilHost(tui);
    const handle = host.showOverlay(panel());
    handle.hide();
    handle.hide();
    expect(tui.overlays).toHaveLength(2);
  });
});
