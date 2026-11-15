import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** How this process was shipped; the update check and upgrade copy key off it. */
export type Channel = "npm" | "release" | "dev";

export type PackageManager = "npm" | "pnpm" | "bun";

declare const __CETAS_VERSION__: string | undefined;

type Env = Record<string, string | undefined>;

export function bunGlobalRoot(env: Env = process.env, home: string = homedir()): string {
  return join(env.BUN_INSTALL ?? join(home, ".bun"), "install", "global", "node_modules");
}

function normalizePath(value: string): string {
  return value.split("\\").join("/");
}

/** Only globally managed paths qualify for managed updates. */
export function matchGlobalManager(
  entryPath: string,
  env: Env = process.env,
  home: string = homedir(),
): PackageManager | undefined {
  const entry = normalizePath(entryPath);
  if (entry.startsWith(`${normalizePath(bunGlobalRoot(env, home))}/`)) return "bun";
  return entry.includes("/pnpm/global/") ? "pnpm" : undefined;
}

export function classifyChannel(
  bunVersion: string | undefined,
  bunMain: string | undefined,
  env: Env = process.env,
  home: string = homedir(),
): Channel {
  if (bunVersion === undefined) return "npm";
  if (bunMain?.startsWith("/$bunfs/")) return "release";
  // Managed installations use the update channel; source checkouts do not.
  return bunMain !== undefined && matchGlobalManager(bunMain, env, home) !== undefined
    ? "npm"
    : "dev";
}

/** The entry module path, symlink-resolved so shim indirection cannot hide the install root. */
function entryPath(): string | undefined {
  const bun = (globalThis as { Bun?: { main?: string } }).Bun;
  const raw = bun?.main ?? process.argv[1];
  if (raw === undefined || raw === "") return undefined;
  try {
    return realpathSync(raw);
  } catch {
    return raw;
  }
}

export function detectChannel(): Channel {
  const bun = (globalThis as { Bun?: { main?: string } }).Bun;
  return classifyChannel(process.versions.bun, entryPath() ?? bun?.main);
}

export function detectPackageManager(
  env: Env = process.env,
  home: string = homedir(),
): PackageManager {
  return matchGlobalManager(entryPath() ?? "", env, home) ?? "npm";
}

/** Missing local version metadata must not prevent startup. */
export function cetasVersion(): string {
  if (typeof __CETAS_VERSION__ === "string") return __CETAS_VERSION__;
  try {
    const pkg = JSON.parse(
      readFileSync(join(import.meta.dir, "../../package.json"), "utf8"),
    ) as { version?: string };
    return typeof pkg.version === "string" ? pkg.version : "dev";
  } catch {
    return "dev";
  }
}
