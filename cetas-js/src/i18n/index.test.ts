import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getLocale, normalizeLocale, resolveLocale, saveLocalePreference, setLocale, t, tf } from "./index.ts";

afterEach(() => setLocale("en-US"));

test("the same catalog renders in English and Chinese", () => {
  expect(normalizeLocale("zh_CN.UTF-8")).toBe("zh-CN");
  setLocale("zh-CN");
  expect(t("welcome.tagline")).toContain("智能体");
  expect(tf("notice.queued", { count: 3 })).toContain("3");
});

test("CLI overrides environment, which overrides shared settings", () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-i18n-"));
  try {
    mkdirSync(join(home, ".cetas"));
    writeFileSync(join(home, ".cetas", "settings.json"), '{"providers":{"example":{}},"ui":{"theme":"dark"}}');
    saveLocalePreference(home, "zh-CN");
    const root = JSON.parse(readFileSync(join(home, ".cetas", "settings.json"), "utf8"));
    expect(root.providers).toEqual({ example: {} });
    expect(root.ui.theme).toBe("dark");
    expect(resolveLocale({ argv: [], home, env: { LANG: "en_US.UTF-8" } })).toBe("zh-CN");
    expect(resolveLocale({ argv: [], home, env: { CETAS_LANG: "en-US" } })).toBe("en-US");
    expect(resolveLocale({ argv: ["--lang", "zh-CN"], home, env: { CETAS_LANG: "en-US" } })).toBe("zh-CN");
    expect(getLocale()).toBe("en-US");
  } finally { rmSync(home, { recursive: true, force: true }); }
});
