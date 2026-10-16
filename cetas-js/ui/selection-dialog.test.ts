import { describe, expect, test } from "bun:test";
import type { Component, OverlayHandle } from "@earendil-works/pi-tui";
import { SelectionDialog } from "./selection-dialog.ts";

describe("SelectionDialog", () => {
  test("allows exactly one active modal and correctly clears the handle", () => {
    let hidden = 0;
    const dialog = new SelectionDialog({
      showOverlay: (_c: Component) => ({ hide: () => { hidden++; } }) as OverlayHandle,
      requestRender: () => {},
    }, { selectedPrefix: (s) => s, selectedText: (s) => s,
         description: (s) => s, scrollInfo: (s) => s, noMatch: (s) => s });
    const opts = { title: "Choose", items: [{ value: "a", label: "A" }],
      onSelect: (_v: string) => {}, onCancel: () => {} };
    dialog.open(opts);
    expect(dialog.isActive).toBe(true);
    expect(() => dialog.open(opts)).toThrow("already open");
    dialog.hide();
    expect(hidden).toBe(1);
    expect(dialog.isActive).toBe(false);
    dialog.open(opts);
    dialog.hide();
    expect(hidden).toBe(2);
  });
});
