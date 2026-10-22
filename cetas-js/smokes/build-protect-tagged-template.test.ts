import { expect, test } from "bun:test";
import { parse } from "acorn";
import { protect } from "../build-protect.ts";

test("protected distribution preserves tagged template syntax", () => {
  const source = "const value = String.raw`hello world`; console.log(value);";
  const result = protect(source);
  expect(() => parse(result.code, { ecmaVersion: "latest", sourceType: "module" })).not.toThrow();
  expect(result.stats.skipped["tagged-template"]).toBeGreaterThan(0);
});
