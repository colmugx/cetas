import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import {
  AuthPromptOverlay,
  parseAuthPromptRequest,
} from "./auth-prompt-overlay.ts";

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

describe("provider-neutral auth prompts", () => {
  test("parses secret and select requests without provider branching", () => {
    expect(parseAuthPromptRequest({
      type: "secret",
      message: "API key",
    })).toEqual({ type: "secret", message: "API key" });
    expect(parseAuthPromptRequest({
      type: "select",
      message: "Choose login method",
      options: [{ id: "oauth", label: "OAuth", description: "Subscription" }],
    })).toEqual({
      type: "select",
      message: "Choose login method",
      options: [{ id: "oauth", label: "OAuth", description: "Subscription" }],
    });
  });

  test("rejects malformed or empty option payloads", () => {
    expect(() => parseAuthPromptRequest({ type: "select", message: "x", options: [] })).toThrow(
      "non-empty array",
    );
    expect(() => parseAuthPromptRequest({ type: "secret", message: "\u0000" })).toThrow(
      "must not be empty",
    );
  });

  test("returns a selected provider-neutral option", async () => {
    const tui = new FakeTui();
    const overlay = new AuthPromptOverlay(tui as never);
    const result = overlay.request({
      type: "select",
      message: "Choose login method",
      options: [
        { id: "api_key", label: "API key" },
        { id: "oauth", label: "OAuth" },
      ],
    });
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    await expect(result).resolves.toBe("oauth");
    expect(overlay.isActive).toBe(false);
  });

  test("cancellation rejects without exposing a secret value", async () => {
    const tui = new FakeTui();
    const overlay = new AuthPromptOverlay(tui as never);
    const result = overlay.request({ type: "secret", message: "API key" });
    for (const character of "secret-key") tui.shown!.handleInput!(character);
    const rendered = tui.shown!.render(80).join("\n");
    expect(rendered).not.toContain("secret-key");
    expect(rendered).toContain("•");
    // Input is intentionally not rendered as plain text; Escape rejects the
    // request and the caller sees only a cancellation diagnostic.
    tui.shown!.handleInput!("\u001b");
    await expect(result).rejects.toThrow("cancelled");
    expect(overlay.isActive).toBe(false);
  });
});
