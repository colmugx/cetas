import { describe, expect, test } from "bun:test";
import { contrastRatio } from "./color-contrast.ts";
import { terminalSurfaceColors, theme } from "./theme.ts";

describe("terminal-aware Cetas surfaces", () => {
  test("light and dark terminals get different readable user backgrounds", () => {
    const white = { r: 255, g: 255, b: 255 };
    const black = { r: 0, g: 0, b: 0 };
    const light = terminalSurfaceColors({ foreground: black, background: white });
    const dark = terminalSurfaceColors({ foreground: white, background: black });
    expect(light.user).toBeDefined();
    expect(dark.user).toBeDefined();
    expect(light.user).not.toEqual(dark.user);
    expect(contrastRatio(black, light.user!)).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio(white, dark.user!)).toBeGreaterThanOrEqual(4.5);
    for (const value of Object.values(light)) {
      expect(contrastRatio(black, value!)).toBeGreaterThanOrEqual(4.5);
    }
    for (const value of Object.values(dark)) {
      expect(contrastRatio(white, value!)).toBeGreaterThanOrEqual(4.5);
    }
  });

  test("missing OSC foreground or background never forces a dark surface", () => {
    expect(terminalSurfaceColors({})).toEqual({});
    expect(terminalSurfaceColors({ foreground: { r: 0, g: 0, b: 0 } })).toEqual({});
    expect(terminalSurfaceColors({ background: { r: 255, g: 255, b: 255 } })).toEqual({});
  });

  test("low-contrast terminal defaults fall back to transparent boxes", () => {
    const nearWhite = { r: 250, g: 250, b: 250 };
    expect(terminalSurfaceColors({
      foreground: nearWhite,
      background: { r: 255, g: 255, b: 255 },
    }).user).toBeUndefined();
  });

  test("user text never hardcodes white on the prompt prefix", () => {
    expect(theme.user("> prompt")).toBe("> prompt");
  });
});
