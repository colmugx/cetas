// Scan the user-level pi package directory (`<home>/.cetas/pi-packages`)
// and load every declared extension entry through the MoonBit bridge. A
// missing directory is a clean no-op: hosts without pi packages behave
// exactly as before this loader existed.
import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

/** One load run: discovered packages, newly loaded entries, per-package failures. */
export interface PiPackagesSummary {
  packages: number;
  entries: number;
  failures: readonly string[];
}

export function describePiError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Directories that may hold a pi package, in scan order: the umbrella
 * layout's `node_modules/<dependency>` for each key in
 * `<root>/package.json`, then direct package subdirectories (secondary,
 * no-umbrella layout). Missing root yields no candidates; any other read
 * error propagates to the caller.
 */
async function candidatePackageDirs(root: string): Promise<string[]> {
  const dirents = await readdir(root, { withFileTypes: true });
  const dirs: string[] = [];
  try {
    const manifest = JSON.parse(
      await readFile(join(root, "package.json"), "utf8"),
    ) as { dependencies?: Record<string, unknown> };
    for (const name of Object.keys(manifest.dependencies ?? {})) {
      dirs.push(join(root, "node_modules", name));
    }
  } catch {
    // No readable umbrella manifest — the direct-dirs scan still applies.
  }
  for (const dirent of dirents) {
    if (dirent.isDirectory() && dirent.name !== "node_modules") {
      dirs.push(join(root, dirent.name));
    }
  }
  return [...new Set(dirs)];
}

/** The package's `pi.extensions` entry paths, or undefined when absent/invalid. */
async function piExtensionsOf(dir: string): Promise<readonly string[] | undefined> {
  let raw: string;
  try {
    raw = await readFile(join(dir, "package.json"), "utf8");
  } catch {
    return undefined;
  }
  try {
    const manifest = JSON.parse(raw) as { pi?: { extensions?: unknown } };
    const extensions = manifest.pi?.extensions;
    if (!Array.isArray(extensions) || extensions.length === 0) return undefined;
    if (extensions.some((entry) => typeof entry !== "string")) return undefined;
    return extensions as readonly string[];
  } catch {
    return undefined;
  }
}

/**
 * Scan `piPackagesRoot` and load every pi extension entry via `loadEntry`
 * (a `file://` URL per entry). Per-package failures are collected, never
 * thrown; `loaded` deduplicates across repeated runs (agent recomposition).
 */
export async function scanAndLoadPiPackages(
  piPackagesRoot: string,
  loadEntry: (entryFileUrl: string) => Promise<void>,
  loaded?: Set<string>,
): Promise<PiPackagesSummary> {
  let dirs: string[];
  try {
    dirs = await candidatePackageDirs(piPackagesRoot);
  } catch (error) {
    if (
      (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT" ||
      (error as NodeJS.ErrnoException | undefined)?.code === "ENOTDIR"
    ) {
      return { packages: 0, entries: 0, failures: [] };
    }
    return { packages: 0, entries: 0, failures: [describePiError(error)] };
  }
  let packages = 0;
  let entries = 0;
  const failures: string[] = [];
  for (const dir of dirs) {
    const extensions = await piExtensionsOf(dir);
    if (extensions === undefined) continue;
    packages += 1;
    for (const entry of extensions) {
      const url = pathToFileURL(resolve(dir, entry)).href;
      if (loaded?.has(url) === true) continue;
      try {
        await loadEntry(url);
        loaded?.add(url);
        entries += 1;
      } catch (error) {
        failures.push(`${dir}: ${describePiError(error)}`);
      }
    }
  }
  return { packages, entries, failures };
}
