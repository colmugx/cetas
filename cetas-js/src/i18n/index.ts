import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { catalog, type MessageKey } from "./generated.ts";

export type Locale = keyof typeof catalog;
let activeLocale: Locale = "en-US";
export const getLocale = (): Locale => activeLocale;
export const setLocale = (locale: Locale): void => { activeLocale = locale; };
export function normalizeLocale(raw: string | undefined): Locale | undefined {
  const normalized = raw?.trim().split(/[.@]/, 1)[0]?.replaceAll("_", "-").toLowerCase();
  if (!normalized || normalized === "auto") return undefined;
  if (normalized === "zh" || normalized.startsWith("zh-")) return "zh-CN";
  if (normalized === "en" || normalized.startsWith("en-")) return "en-US";
  return undefined;
}
export function t(key: MessageKey): string {
  return catalog[activeLocale][key] ?? catalog["en-US"][key] ?? key;
}
export function tOr(key: string, fallback: string): string {
  const translations = catalog[activeLocale] as Record<string, string>;
  return translations[key] ?? fallback;
}
export function tf(key: MessageKey, params: Record<string, string | number>): string {
  return t(key).replace(/\{([a-zA-Z_]\w*)\}/g, (match, name: string) =>
    params[name] === undefined ? match : String(params[name]));
}
interface LocaleOptions {
  argv?: readonly string[];
  env?: NodeJS.ProcessEnv;
  home?: string;
  systemLocale?: string;
}
export function resolveLocale(options: LocaleOptions = {}): Locale {
  const argv = options.argv ?? process.argv.slice(2);
  let flag: string | undefined;
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--lang") {
      if (!argv[index + 1]) throw new Error("--lang requires en-US or zh-CN");
      flag = argv[++index];
    } else if (arg.startsWith("--lang=")) {
      flag = arg.slice("--lang=".length);
    }
  }
  if (flag !== undefined) {
    const locale = normalizeLocale(flag);
    if (!locale && flag !== "auto") throw new Error("Unsupported --lang value: " + flag);
    if (locale) return locale;
  }
  const env = options.env ?? process.env;
  if (env.CETAS_LANG) {
    const locale = normalizeLocale(env.CETAS_LANG);
    if (!locale && env.CETAS_LANG !== "auto") throw new Error("Unsupported CETAS_LANG: " + env.CETAS_LANG);
    if (locale) return locale;
  }
  const home = options.home ?? homedir();
  const path = join(home, ".cetas", "settings.json");
  if (existsSync(path)) {
    const root: unknown = JSON.parse(readFileSync(path, "utf8").replace(/^\uFEFF/, ""));
    if (!root || typeof root !== "object" || Array.isArray(root)) throw new Error("settings.json must be an object");
    const ui = (root as Record<string, unknown>).ui;
    if (ui !== undefined && (ui === null || typeof ui !== "object" || Array.isArray(ui)))
      throw new Error("settings.ui must be an object");
    const stored = (ui as Record<string, unknown> | undefined)?.locale;
    if (stored !== undefined && typeof stored !== "string") throw new Error("settings.ui.locale must be a string");
    if (stored && stored !== "auto") {
      const locale = normalizeLocale(stored);
      if (!locale) throw new Error("Unsupported settings.ui.locale: " + stored);
      return locale;
    }
  }
  return normalizeLocale(env.LC_ALL || env.LC_MESSAGES || env.LANG || options.systemLocale ||
    Intl.DateTimeFormat().resolvedOptions().locale) ?? "en-US";
}
export function saveLocalePreference(home: string, locale: Locale): void {
  const dir = join(home, ".cetas");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, "settings.json");
  const root: unknown = existsSync(path)
    ? JSON.parse(readFileSync(path, "utf8").replace(/^\uFEFF/, ""))
    : { providers: {} };
  if (!root || typeof root !== "object" || Array.isArray(root)) throw new Error("settings.json must be an object");
  const object = root as Record<string, unknown>;
  if (object.ui !== undefined && (object.ui === null || typeof object.ui !== "object" || Array.isArray(object.ui)))
    throw new Error("settings.ui must be an object");
  object.ui = { ...(object.ui as Record<string, unknown> | undefined), locale };
  const tmp = join(dir, ".settings-language-" + randomUUID() + ".tmp");
  try {
    writeFileSync(tmp, JSON.stringify(object, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(tmp, path);
  } finally {
    rmSync(tmp, { force: true });
  }
}
