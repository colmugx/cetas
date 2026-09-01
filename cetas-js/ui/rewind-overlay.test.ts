import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import type { RewindPoint } from "../src/transcript/rewind-points.ts";
import { RewindOverlay } from "./rewind-overlay.ts";

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

function point(messageIndex: number, preview: string): RewindPoint {
  return { messageIndex, preview };
}

describe("rewind overlay contract", () => {
  test("open activates the overlay and renders each preview with its index", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    overlay.open(
      [point(0, "first prompt"), point(2, "second prompt")],
      () => {},
      () => {},
    );
    expect(overlay.isActive).toBe(true);
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("first prompt");
    expect(rendered).toContain("second prompt");
    expect(rendered).toContain("message #2");
  });

  test("arrow down plus enter picks the highlighted rewind point and closes once", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    const picked: RewindPoint[] = [];
    let closed = 0;
    overlay.open(
      [point(0, "first prompt"), point(3, "second prompt")],
      (p) => picked.push(p),
      () => {
        closed++;
      },
    );
    expect(overlay.isActive).toBe(true);
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual([{ messageIndex: 3, preview: "second prompt" }]);
    expect(closed).toBe(1);
    expect(overlay.isActive).toBe(false);
  });

  test("right arrow moves down and left arrow wraps to the bottom", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    const picked: RewindPoint[] = [];
    overlay.open(
      [point(0, "first prompt"), point(3, "second prompt")],
      (p) => picked.push(p),
      () => {},
    );
    tui.shown!.handleInput!("\u001b[C"); // right → index 1
    tui.shown!.handleInput!("\u001b[D"); // left → index 0
    tui.shown!.handleInput!("\u001b[C"); // right → index 1
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual([{ messageIndex: 3, preview: "second prompt" }]);

    const wrapped: RewindPoint[] = [];
    const overlay2 = new RewindOverlay(tui as never);
    overlay2.open(
      [point(0, "first prompt"), point(3, "second prompt")],
      (p) => wrapped.push(p),
      () => {},
    );
    tui.shown!.handleInput!("\u001b[D"); // left at index 0 wraps to bottom
    tui.shown!.handleInput!("\r");
    expect(wrapped).toEqual([{ messageIndex: 3, preview: "second prompt" }]);
  });

  test("enter on the first row picks message index 0", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    const picked: RewindPoint[] = [];
    overlay.open([point(0, "only prompt")], (p) => picked.push(p), () => {});
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual([{ messageIndex: 0, preview: "only prompt" }]);
    expect(overlay.isActive).toBe(false);
  });

  test("escape closes without picking anything", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    const picked: RewindPoint[] = [];
    let closed = 0;
    overlay.open(
      [point(0, "a"), point(1, "b")],
      (p) => picked.push(p),
      () => {
        closed++;
      },
    );
    tui.shown!.handleInput!("\u001b");
    expect(picked).toEqual([]);
    expect(closed).toBe(1);
    expect(overlay.isActive).toBe(false);
  });

  test("empty list closes immediately without showing anything", () => {
    const tui = new FakeTui();
    const overlay = new RewindOverlay(tui as never);
    let closed = 0;
    overlay.open([], () => {}, () => {
      closed++;
    });
    expect(closed).toBe(1);
    expect(overlay.isActive).toBe(false);
    expect(tui.shown).toBeUndefined();
  });
});
