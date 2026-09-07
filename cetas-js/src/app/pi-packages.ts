// Scan the user-level pi package directory (`<home>/.cetas/pi-packages`)
// and load the declared extension entries of allowlisted packages through
// the MoonBit bridge. The allowlist is the snapshot file
// `<home>/.cetas/pi-packages.json` ({ packages, npmCommand }); a missing,
// empty, or malformed file means ZERO packages load (deny by default — no
// seeding, no exceptions). A missing package directory is a clean no-op.
//
// Entry URLs are routed through the module mirror first: compiled Bun
// binaries cannot resolve a package's own imports (see pi-module-mirror.ts).
// `CETAS_PI_MIRROR=0` bypasses the mirror and imports the original file URL.
import { readdir, readFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { mirrorPiEntry } from "./pi-module-mirror.ts";

/** One load run: discovered packages, newly loaded entries, per-package failures. */
export interface PiPackagesSummary {
  packages: number;
  entries: number;
  failures: readonly string[];
  /** Mirror diagnostics (e.g. unresolved optional imports); not load failures. */
  warnings?: readonly string[];
  /** Discovered pi packages denied by the allowlist (name + reason). */
  skipped?: readonly PiPackageSkip[];
  /** Allowlisted package names with at least one entry loaded this run. */
  loadedPackages?: readonly string[];
  /** Allowlisted package names with at least one entry failure this run. */
  failedPackages?: readonly string[];
}

/** A discovered pi package that the allowlist denied. */
export interface PiPackageSkip {
  name: string;
  reason: string;
}

export const DEFAULT_PI_NPM_COMMAND = "npm";

/**
 * Parsed snapshot file: `packages` doubles as the load allowlist and the
 * install/remove target list; `npmCommand` is the package manager binary
 * used by /pi install|remove. */
export interface PiPackagesConfig {
  packages: readonly string[];
  npmCommand: string;
  /** False when the file is missing (silent deny — normal for pi-free hosts). */
  present: boolean;
  /** Non-fatal parse diagnostics (malformed JSON, dropped entries, …). */
  warnings: readonly string[];
}

/**
 * Package-manager resolution for the snapshot's `npmCommand` field: a
 * non-empty string wins, otherwise the first usable entry of an array,
 * otherwise the default `npm`.
 */
export function resolvePiPackageManager(value: unknown): string {
  if (typeof value === "string" && value.trim() !== "") return value.trim();
  if (Array.isArray(value)) {
    const first = value.find((entry) => typeof entry === "string" && entry.trim() !== "");
    if (first !== undefined) return (first as string).trim();
  }
  return DEFAULT_PI_NPM_COMMAND;
}

/** Tolerant snapshot parse: malformed input degrades to an empty allowlist. */
export function parsePiPackagesConfig(raw: string | undefined): PiPackagesConfig {
  if (raw === undefined) {
    return { packages: [], npmCommand: DEFAULT_PI_NPM_COMMAND, present: false, warnings: [] };
  }
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (error) {
    return {
      packages: [],
      npmCommand: DEFAULT_PI_NPM_COMMAND,
      present: true,
      warnings: [
        `pi-packages.json is not valid JSON (${describePiError(error)}); allowlist treated as empty`,
      ],
    };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return {
      packages: [],
      npmCommand: DEFAULT_PI_NPM_COMMAND,
      present: true,
      warnings: ["pi-packages.json must be a JSON object; allowlist treated as empty"],
    };
  }
  const record = value as Record<string, unknown>;
  const warnings: string[] = [];
  const packages: string[] = [];
  if (record.packages !== undefined) {
    if (Array.isArray(record.packages)) {
      for (const entry of record.packages) {
        if (typeof entry === "string" && entry.trim() !== "") {
          const name = entry.trim();
          if (!packages.includes(name)) packages.push(name);
        } else {
          warnings.push(`pi-packages.json packages entry ignored (not a non-empty string): ${JSON.stringify(entry)}`);
        }
      }
    } else {
      warnings.push("pi-packages.json packages must be an array of strings; allowlist treated as empty");
    }
  }
  let npmCommand: string;
  if (record.npmCommand === undefined) {
    npmCommand = DEFAULT_PI_NPM_COMMAND;
  } else {
    npmCommand = resolvePiPackageManager(record.npmCommand);
    const usable =
      typeof record.npmCommand === "string"
        ? record.npmCommand.trim() !== ""
        : Array.isArray(record.npmCommand) &&
          record.npmCommand.some((entry) => typeof entry === "string" && entry.trim() !== "");
    if (!usable) {
      warnings.push("pi-packages.json npmCommand has no usable value; defaulting to npm");
    }
  }
  return { packages, npmCommand, present: true, warnings };
}

/** Read + parse the snapshot file; a missing file is a silent empty allowlist. */
export async function readPiPackagesConfig(configPath: string): Promise<PiPackagesConfig> {
  let raw: string | undefined;
  try {
    raw = await readFile(configPath, "utf8");
  } catch {
    return parsePiPackagesConfig(undefined);
  }
  return parsePiPackagesConfig(raw);
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

/**
 * The package's `name` and `pi.extensions` entry paths, or undefined when
 * the manifest is absent/invalid (not a pi package).
 */
async function piManifestOf(
  dir: string,
): Promise<{ name?: string; extensions: readonly string[] } | undefined> {
  let raw: string;
  try {
    raw = await readFile(join(dir, "package.json"), "utf8");
  } catch {
    return undefined;
  }
  let manifest: { name?: unknown; pi?: { extensions?: unknown } };
  try {
    manifest = JSON.parse(raw) as { name?: unknown; pi?: { extensions?: unknown } };
  } catch {
    return undefined;
  }
  const extensions = manifest.pi?.extensions;
  if (!Array.isArray(extensions) || extensions.length === 0) return undefined;
  if (extensions.some((entry) => typeof entry !== "string")) return undefined;
  return {
    ...(typeof manifest.name === "string" && manifest.name !== "" ? { name: manifest.name } : {}),
    extensions: extensions as readonly string[],
  };
}

/**
 * Mirror the entry (unless bypassed) and return the URL to hand to
 * `loadEntry`: the compiled-binary import path needs every specifier
 * rewritten to an absolute file URL. Never throws; on mirror failure the
 * original URL is returned so behavior matches pre-mirror hosts.
 */
function loadUrlFor(sourceUrl: string, warnings: string[]): string {
  if (process.env.CETAS_PI_MIRROR === "0" || !sourceUrl.startsWith("file:")) return sourceUrl;
  try {
    const outcome = mirrorPiEntry(fileURLToPath(sourceUrl));
    warnings.push(...outcome.warnings.map((warning) => `${sourceUrl}: ${warning}`));
    return outcome.url;
  } catch (error) {
    warnings.push(`${sourceUrl}: mirroring failed, importing original: ${describePiError(error)}`);
    return sourceUrl;
  }
}

/**
 * Scan `piPackagesRoot` and load the pi extension entries of allowlisted
 * packages via `loadEntry` (a `file://` URL per entry, mirrored for import
 * resolution). The allowlist comes from the snapshot file next to the
 * package root (`<root>/../pi-packages.json`, overridable via `options`);
 * missing/empty/malformed means zero packages load (deny by default).
 * Per-package failures are collected, never thrown; `loaded` deduplicates
 * across repeated runs (agent recomposition).
 */
export async function scanAndLoadPiPackages(
  piPackagesRoot: string,
  loadEntry: (entryFileUrl: string) => Promise<void>,
  loaded?: Set<string>,
  options?: { configPath?: string },
): Promise<PiPackagesSummary> {
  const configPath = options?.configPath ?? join(dirname(piPackagesRoot), "pi-packages.json");
  const config = await readPiPackagesConfig(configPath);
  const allow = new Set(config.packages);
  let dirs: string[];
  try {
    dirs = await candidatePackageDirs(piPackagesRoot);
  } catch (error) {
    if (
      (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT" ||
      (error as NodeJS.ErrnoException | undefined)?.code === "ENOTDIR"
    ) {
      return summaryFor(config, 0, 0, [], [], []);
    }
    return summaryFor(config, 0, 0, [describePiError(error)], [], []);
  }
  let packages = 0;
  let entries = 0;
  const failures: string[] = [];
  const warnings: string[] = [];
  const skipped: PiPackageSkip[] = [];
  const loadedNames: string[] = [];
  const failedNames: string[] = [];
  for (const dir of dirs) {
    const manifest = await piManifestOf(dir);
    if (manifest === undefined) continue;
    const name = manifest.name ?? basename(dir);
    if (!allow.has(name) && !allow.has(basename(dir))) {
      skipped.push({ name, reason: "not in allowlist" });
      continue;
    }
    packages += 1;
    let pkgLoaded = false;
    let pkgFailed = false;
    for (const entry of manifest.extensions) {
      const sourceUrl = pathToFileURL(resolve(dir, entry)).href;
      if (loaded?.has(sourceUrl) === true) {
        pkgLoaded = true;
        continue;
      }
      try {
        await loadEntry(loadUrlFor(sourceUrl, warnings));
        loaded?.add(sourceUrl);
        entries += 1;
        pkgLoaded = true;
      } catch (error) {
        pkgFailed = true;
        failures.push(`${dir}: ${describePiError(error)}`);
      }
    }
    if (pkgFailed) failedNames.push(name);
    else if (pkgLoaded) loadedNames.push(name);
  }
  return summaryFor(config, packages, entries, failures, skipped, loadedNames, failedNames, warnings);
}

/** Merge config diagnostics into the run summary (additive fields omitted when empty). */
function summaryFor(
  config: PiPackagesConfig,
  packages: number,
  entries: number,
  failures: string[],
  skipped: PiPackageSkip[],
  loadedNames: string[],
  failedNames: string[] = [],
  warnings: string[] = [],
): PiPackagesSummary {
  const allWarnings = [...config.warnings, ...warnings];
  return {
    packages,
    entries,
    failures,
    ...(allWarnings.length === 0 ? {} : { warnings: allWarnings }),
    ...(skipped.length === 0 ? {} : { skipped }),
    ...(loadedNames.length === 0 ? {} : { loadedPackages: loadedNames }),
    ...(failedNames.length === 0 ? {} : { failedPackages: failedNames }),
  };
}
