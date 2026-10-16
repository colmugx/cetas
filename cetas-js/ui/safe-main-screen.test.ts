import { describe, expect, test } from "bun:test";
import { CURSOR_MARKER, renderFakeCursor, visibleWidth } from "@earendil-works/pi-tui";
import { CetasTuiMainScreen, fitTerminalLine, fitTerminalLines } from "./safe-main-screen.ts";

describe("Cetas main-screen width boundary", () => {
  const cases = [
    "x".repeat(300),
    "中文字符和长长长长的文件名称".repeat(10),
    "🧑‍💻✨👩🏽‍🚀🤝".repeat(15),
    "\x1b[31mred and very long text\x1b[0m",
    "\x1b]8;;https://example.com\x07hyperlinked extra long text\x1b]8;;\x07",
    "\x1b]133;A\x07" + "x".repeat(100) + "\x1b]133;B\x07",
    CURSOR_MARKER + renderFakeCursor("cursor here") + "x".repeat(100),
  ];
  for (const width of [0, 1, 2, 8, 12, 20, 40, 80, 120, 200]) {
    test(`every text line fits ${width} columns`, () => {
      for (const raw of cases) {
        expect(visibleWidth(fitTerminalLine(raw, width))).toBeLessThanOrEqual(width);
      }
    });
  }

  test("preserves terminal image protocol bytes", () => {
    for (const image of ["\x1b_Ga=T,f=100;abc\x1b\\", "\x1b]1337;File=name=a:abc\x07"]) {
      expect(fitTerminalLine(image, 1)).toBe(image);
    }
  });

  test("preserves terminal shell integration markers after clipping", () => {
    const line = "\x1b]133;A\x07" + "wide text".repeat(20) + "\x1b]133;B\x07";
    const clipped = fitTerminalLine(line, 8);
    expect(clipped).toContain("\x1b]133;A\x07");
    expect(clipped.endsWith("\x1b]133;B\x07")).toBe(true);
  });

  test("preserves fake-cursor balancing at the clipped column", () => {
    const original = CURSOR_MARKER + renderFakeCursor("focused cursor") + "x".repeat(100);
    const clipped = fitTerminalLine(original, 2);
    expect(clipped).toContain(CURSOR_MARKER);
    expect(clipped).toContain("\x1b_pi:fc\x07");
    expect(clipped).toContain("\x1b_pi:/fc\x07");
    expect(visibleWidth(clipped)).toBeLessThanOrEqual(2);
  });

  test("does not alter lines already in bounds", () => {
    const line = "\x1b[34m你好\x1b[0m";
    expect(fitTerminalLine(line, 20)).toBe(line);
  });

  test("normalizes root lines before pi-tui's compositor", () => {
    const tui = new CetasTuiMainScreen({ getColumns: () => 8, getRows: () => 24 } as never);
    tui.addChild({ render: () => ["long unwrapped code output", "正常"] , invalidate: () => {} });
    expect(fitTerminalLines(tui.render(8), 8).every((line) => visibleWidth(line) <= 8)).toBe(true);
  });
});
