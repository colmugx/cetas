import { describe, expect, test } from "bun:test";
import type { Component, OverlayHandle } from "@earendil-works/pi-tui";
import { MessageDialog } from "./message-dialog.ts";

function harness() {
  let component: Component | undefined;
  let hides = 0;
  const dialog = new MessageDialog({
    showOverlay: (panel) => {
      component = panel;
      return { hide: () => { hides++; } } as OverlayHandle;
    },
    requestRender: () => {},
  });
  return { dialog, panel: () => component, hides: () => hides };
}

describe("MessageDialog", () => {
  test("key dismisses and settles awaited dialog", async () => {
    const h = harness();
    const pending = h.dialog.show("quota");
    h.panel()?.handleInput?.("x");
    await pending;
    expect(h.hides()).toBe(1);
  });
  test("shutdown hide settles and second open is possible", async () => {
    const h = harness();
    const pending = h.dialog.show("first");
    h.dialog.hide();
    await pending;
    await h.dialog.show("already aborted", AbortSignal.abort());
    expect(h.hides()).toBe(1);
  });
});
