import { describe, expect, test } from "bun:test";
import { Container, type Component } from "@earendil-works/pi-tui";

import {
  UiRenderHost,
  UiRequestOverlay,
  createUiRequestCallback,
} from "./extension-ui.ts";

class FakeTui {
  renderCount = 0;
  shown?: Component;
  hideCount = 0;

  requestRender(): void {
    this.renderCount++;
  }

  showOverlay(component: Component) {
    this.shown = component;
    return {
      hide: () => {
        this.hideCount++;
      },
      setHidden() {},
      isHidden: () => false,
      focus() {},
      unfocus() {},
      isFocused: () => true,
    };
  }
}

describe("UiRenderHost", () => {
  test("replaces a keyed render instead of appending", () => {
    const tui = new FakeTui();
    const status = new Container();
    const notice = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, { status, notice, widget });

    host.render({
      slot: "status",
      key: "goal.status",
      title: "Goal",
      body: { type: "text", text: "first" },
    });
    host.render({
      slot: "status",
      key: "goal.status",
      title: "Goal",
      body: { type: "text", text: "second" },
    });

    expect(status.children).toHaveLength(1);
    expect(status.render(80).join("\n")).toContain("second");
    expect(status.render(80).join("\n")).not.toContain("first");
    expect(tui.renderCount).toBe(2);
  });

  test("maps render slots to independent mounts", () => {
    const tui = new FakeTui();
    const status = new Container();
    const notice = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, { status, notice, widget });

    host.render({
      slot: "notice",
      key: "workflow.notice",
      title: "Workflow",
      body: { type: "lines", lines: ["one", "two"] },
    });
    host.render({
      slot: "widget",
      key: "goal.values",
      title: "Goal",
      body: {
        type: "key_value",
        entries: [{ key: "state", value: "running" }],
      },
    });

    expect(status.children).toHaveLength(0);
    expect(notice.render(80).join("\n")).toContain("• one");
    expect(widget.render(80).join("\n")).toContain("running");
  });

  test("rejects invalid progress rather than clamping it", () => {
    const tui = new FakeTui();
    const host = new UiRenderHost(tui as never, {
      status: new Container(),
      notice: new Container(),
      widget: new Container(),
    });

    expect(() =>
      host.render({
        slot: "status",
        key: "invalid",
        title: "Invalid",
        body: { type: "progress", current: 1.1 },
      }),
    ).toThrow("within [0, 1]");
  });
});

describe("UiRequestOverlay", () => {
  test("resolves a select request from the focused overlay", async () => {
    const tui = new FakeTui();
    const overlay = new UiRequestOverlay(tui as never);
    const responsePromise = overlay.request({
      type: "select",
      title: "Choose",
      options: ["alpha", "beta"],
      default_index: 1,
    });

    expect(tui.shown).toBeDefined();
    tui.shown!.handleInput!("\r");

    await expect(responsePromise).resolves.toEqual({
      type: "selected",
      index: 1,
    });
    expect(tui.hideCount).toBe(1);
  });

  test("rejects concurrent requests explicitly", async () => {
    const tui = new FakeTui();
    const overlay = new UiRequestOverlay(tui as never);
    const first = overlay.request({
      type: "confirm",
      prompt: "Continue?",
      default_yes: true,
    });

    await expect(
      overlay.request({
        type: "input",
        prompt: "Name",
      }),
    ).rejects.toThrow("concurrent UiRequest");

    tui.shown!.handleInput!("\u001b");
    await expect(first).resolves.toEqual({ type: "cancelled" });
  });

  test("cancels an active request during host shutdown", async () => {
    const tui = new FakeTui();
    const overlay = new UiRequestOverlay(tui as never);
    const response = overlay.request({
      type: "input",
      prompt: "Name",
    });

    overlay.cancel();

    await expect(response).resolves.toEqual({ type: "cancelled" });
    expect(tui.hideCount).toBe(1);
  });

  test("builds a correlated ui_response for the MoonBit Promise bridge", async () => {
    const tui = new FakeTui();
    const callback = createUiRequestCallback(
      new UiRequestOverlay(tui as never),
      1_000,
    );
    const responsePromise = callback(
      JSON.stringify({
        type: "ui_request",
        request_id: "request-7",
        request: {
          type: "confirm",
          prompt: "Apply?",
          default_yes: false,
        },
      }),
    );

    tui.shown!.handleInput!("\r");

    await expect(responsePromise).resolves.toBe(
      JSON.stringify({
        type: "ui_response",
        request_id: "request-7",
        response: { type: "no" },
      }),
    );
  });

  test("rejects malformed request events", async () => {
    const callback = createUiRequestCallback(
      new UiRequestOverlay(new FakeTui() as never),
      1_000,
    );
    await expect(
      callback(
        JSON.stringify({
          type: "ui_request",
          request_id: "",
          request: { type: "confirm", prompt: "x" },
        }),
      ),
    ).rejects.toThrow("request_id must not be empty");
  });

  test("returns a correlated timeout error and closes the overlay", async () => {
    const tui = new FakeTui();
    const callback = createUiRequestCallback(
      new UiRequestOverlay(tui as never),
      1,
    );
    await expect(
      callback(
        JSON.stringify({
          type: "ui_request",
          request_id: "request-timeout",
          request: {
            type: "input",
            prompt: "Wait",
          },
        }),
      ),
    ).resolves.toBe(
      JSON.stringify({
        type: "ui_response",
        request_id: "request-timeout",
        error: { code: "timeout" },
      }),
    );
    expect(tui.hideCount).toBe(1);
  });
});
