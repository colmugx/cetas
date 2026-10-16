import { describe, expect, test } from "bun:test";
import { stripTerminalSequences } from "@earendil-works/pi-tui";
import { createTerminalActivityStyle, relativeLuminance } from "./terminal-colors.ts";

describe("semantic activity contrast follows terminal defaults", () => {
  test("black vs white terminal backgrounds choose different semantic shades", () => {
    const dark = createTerminalActivityStyle({ background: {r:0,g:0,b:0}, foreground:{r:255,g:255,b:255} });
    const light = createTerminalActivityStyle({ background: {r:255,g:255,b:255}, foreground:{r:0,g:0,b:0} });
    expect(dark("agent","test")).not.toBe(light("agent","test"));
    expect(stripTerminalSequences(dark("question","等待回答"))).toBe("等待回答");
  });
  test("terminal without color reply keeps existing Cetas role styles", () => {
    const style=createTerminalActivityStyle({});
    expect(style("agent","test")).toContain("test");
  });
  test("luminance correctly orders extreme backgrounds", () => {
    expect(relativeLuminance({r:0,g:0,b:0})).toBe(0);
    expect(relativeLuminance({r:255,g:255,b:255})).toBeCloseTo(1);
  });
});
