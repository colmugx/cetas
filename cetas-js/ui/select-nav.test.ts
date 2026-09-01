import { describe, expect, test } from "bun:test";

import { matchesKey } from "@earendil-works/pi-tui";

import { translateSelectArrows } from "./select-nav.ts";

describe("translateSelectArrows", () => {
  test("left/right map onto the vertical arrows SelectList binds", () => {
    const up = translateSelectArrows("\u001b[D");
    const down = translateSelectArrows("\u001b[C");
    expect(matchesKey(up, "up")).toBe(true);
    expect(matchesKey(down, "down")).toBe(true);
  });

  test("vertical arrows and every other key pass through untouched", () => {
    for (const data of ["\u001b[A", "\u001b[B", "\u001b", "\r", "a"]) {
      expect(translateSelectArrows(data)).toBe(data);
    }
  });
});
