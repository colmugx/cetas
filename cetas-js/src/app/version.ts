import { readFileSync } from "node:fs";
import { join } from "node:path";

/** How this process was shipped; the update check and upgrade copy key off it. */
export type Channel = "npm" | "release" | "dev";

declare const __CETAS_VERSION__: string | undefined;

/** Pure decision over the runtime fingerprints (unit-tested). */
export function classifyChannel(
  bunVersion: string | undefined,
  bunMain: string | undefined,
): Channel {
  if (bunVersion === undefined) return "npm";
  // Compiled Bun executables mount the entry module under the $bunfs
  // virtual filesystem; a plain `bun run` reports the real source path.
  return bunMain?.startsWith("/$bunfs/") ? "release" : "dev";
}

export function detectChannel(): Channel {
  const bun = (globalThis as { Bun?: { main?: string } }).Bun;
  return classifyChannel(process.versions.bun, bun?.main);
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
