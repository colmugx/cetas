import { describe, expect, test } from "bun:test";
import { formatQuotaLines } from "./quota-view.ts";

describe("formatQuotaLines", () => {
  test("unavailable provider catalog is explicit", () => {
    expect(formatQuotaLines({ manager: "providers" })).toContain("Provider quota data unavailable.");
  });
  test("malformed cards do not crash and unsafe terminal bytes are stripped", () => {
    const lines = formatQuotaLines({ cards: [null, { provider: "hi\\x1b[31m", windows: [{ name: "5h", remaining: 20 }] }] });
    expect(lines.join("\\n")).toContain("5h: 20% remaining");
    expect(lines.join("\\n")).not.toContain("\\x1b");
  });
  test("empty cards have a useful fallback", () => {
    expect(formatQuotaLines({ cards: [] }).at(-1)).toBe("No accessible quota cards.");
  });
});
