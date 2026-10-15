import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** How this process was shipped; the update check and upgrade copy key off it. */
export type Channel = "npm" | "release" | "dev";

/** Package manager owning the npm-channel install; drives registry and upgrade copy. */
export type PackageManager = "npm" | "pnpm" | "bun";

declare const __CETAS_VERSION__: string | undefined;

type Env = Record<string, string | undefined>;

/** `$BUN_INSTALL/install/global/node_modules` — bun's global package root. */
export function bunGlobalRoot(env: Env = process.env, home: string = homedir()): string {
  return join(env.BUN_INSTALL ?? join(home, ".bun"), "install", "global", "node_modules");
}

function normalizePath(value: string): string {
  return value.split("\\").join("/");
}

/**
 * Pure path decision (unit-tested): the manager owning a package-manager
 * global install, or undefined for anything else (dev checkouts, compiled
 * binaries). bun resolves `~/.bun/bin` shims into its global root; pnpm's
 * global root always contains `/pnpm/global/`.
 */
export function matchGlobalManager(
  entryPath: string,
  env: Env = process.env,
  home: string = homedir(),
): PackageManager | undefined {
  const entry = normalizePath(entryPath);
  if (entry.startsWith(`${normalizePath(bunGlobalRoot(env, home))}/`)) return "bun";
  return entry.includes("/pnpm/global/") ? "pnpm" : undefined;
}

/** Pure decision over the runtime fingerprints (unit-tested). */
export function classifyChannel(
  bunVersion: string | undefined,
  bunMain: string | undefined,
  env: Env = process.env,
  home: string = homedir(),
): Channel {
  if (bunVersion === undefined) return "npm";
  // Compiled Bun executables mount the entry module under the $bunfs
  // virtual filesystem; a plain `bun run` reports the real source path.
  if (bunMain?.startsWith("/$bunfs/")) return "release";
  // Package-manager global installs are release quality and take the npm
  // update channel; only an unresolved real source path is a dev checkout.
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

/** Manager owning this install; npm is the baseline the update flow assumes. */
export function detectPackageManager(
  env: Env = process.env,
  home: string = homedir(),
): PackageManager {
  return matchGlobalManager(entryPath() ?? "", env, home) ?? "npm";
}

/**
 * Release version, injected by build.ts's `define` into the node bundle and
 * the compiled binaries. Dev runs fall back to reading package.json; a
 * missing file degrades to "dev" rather than failing startup.
 */
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
