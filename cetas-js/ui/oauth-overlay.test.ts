import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import {
  OAuthOverlay,
  parseOAuthNotification,
} from "./oauth-overlay.ts";

class FakeTui {
  shown?: Component;
  hideCount = 0;

  showOverlay(component: Component) {
    this.shown = component;
    return {
      hide: () => {
        this.hideCount++;
      },
      setHidden: () => {},
      isHidden: () => false,
      focus: () => {},
      unfocus: () => {},
      isFocused: () => true,
    };
  }

  requestRender(): void {}
}

describe("OAuth UI interaction", () => {
  test("decodes URL, device code, and progress notifications", () => {
    expect(parseOAuthNotification("posoco.oauth", "auth_url", { url: "https://example.test/login" })).toEqual({
      type: "url",
      url: "https://example.test/login",
    });
    expect(parseOAuthNotification("posoco.oauth", "device_code", {
      verification_uri: "https://example.test/device",
      user_code: "ABCD-1234",
    })).toEqual({
      type: "device_code",
      verificationUri: "https://example.test/device",
      userCode: "ABCD-1234",
    });
    expect(parseOAuthNotification("posoco.oauth", "progress", "waiting")).toEqual({
      type: "progress",
      message: "waiting",
    });
    expect(parseOAuthNotification("extension.other", "progress", "ignored")).toBeNull();
  });

  test("keeps OAuth activity visible and renders provider messages", () => {
    const tui = new FakeTui();
    const overlay = new OAuthOverlay(tui as never);
    overlay.show("openai");
    const handled = overlay.notify({
      type: "custom",
      source: "posoco.oauth",
      label: "device_code",
      data: {
        verification_uri: "https://example.test/device",
        user_code: "ABCD-1234",
      },
    });
    expect(handled).toBe(true);
    expect(tui.shown!.render(100).join("\n")).toContain("ABCD-1234");
    overlay.result("Logged in", false);
    expect(tui.shown!.render(100).join("\n")).toContain("Logged in");
    tui.shown!.handleInput!("\r");
    expect(overlay.isActive).toBe(false);
    expect(tui.hideCount).toBe(1);
  });

  test("rejects malformed device notifications", () => {
    expect(() =>
      parseOAuthNotification("posoco.oauth", "device_code", { user_code: "missing-url" }),
    ).toThrow("missing verification_uri");
  });

  test("propagates Escape/close to the application cancellation hook", () => {
    const tui = new FakeTui();
    let cancellations = 0;
    const overlay = new OAuthOverlay(tui as never, () => {
      cancellations += 1;
    });
    overlay.show("kimi");
    tui.shown!.handleInput!("\u001b");
    expect(cancellations).toBe(1);
    expect(overlay.isActive).toBe(false);
  });
});
