// Host-side pi package surface management for the /pi slash command:
// install/remove run the configured package manager inside the umbrella
// directory (`<home>/.cetas/pi-packages`) and mutate the snapshot file
// (`<home>/.cetas/pi-packages.json`); bare /pi and list report the three-way
// state (loaded / skipped / failed) from the last loader summary. Progress
// goes to console lines for v1 (UiPort Notice is out of scope here).
import { existsSync, readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { parsePiPackagesConfig, type PiPackagesSummary } from "./pi-packages.ts";

/** Packages must match this pattern to reach the package manager (shell safety). */
export const PI_PACKAGE_NAME_PATTERN = /^[a-zA-Z0-9@\/._-]+$/;

export interface PiCommandOutcome {
  ok: boolean;
  lines: readonly string[];
}

/** The spawn seam behind install/remove; tests inject a stub. */
export type PiCommandRunner = (
  command: string,
  args: readonly string[],
  cwd: string,
) => Promise<{ code: number; output: string }>;

/** Default runner: argv-spawn without a shell, stdout+stderr captured. */
export function defaultPiCommandRunner(): PiCommandRunner {
  return async (command, args, cwd) => {
    const proc = Bun.spawn([command, ...args], { cwd, stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    return { code: await proc.exited, output: `${stdout}${stderr}`.trim() };
  };
}

export interface PiCommandsDeps {
  home: string;
  /** Reload pi packages into the runtime after an install (idempotent). */
  reload: () => Promise<PiPackagesSummary | undefined>;
  /** Last loader summary without reloading (list must not recompose). */
  lastSummary?: () => PiPackagesSummary | undefined;
  runCommand?: PiCommandRunner;
  log?: (line: string) => void;
}

interface Snapshot {
  /** Raw parsed JSON object, preserved verbatim across package-list edits. */
  raw: Record<string, unknown>;
  packages: string[];
  npmCommand: string;
  warnings: readonly string[];
}

const UMBRELLA_PACKAGE_JSON = { name: "cetas-pi-packages", private: true, type: "module" };

const USAGE = [
  "usage: /pi install <pkg> — install a pi package and add it to the allowlist",
  "       /pi remove <pkg>  — remove a pi package from disk and the allowlist",
  "       /pi list          — show loaded / skipped / failed pi packages",
].join("\n");

const USAGE_HINT = "usage: /pi install|remove|list|help";

export class PiCommands {
  constructor(private readonly deps: PiCommandsDeps) {}

  get home(): string {
    return this.deps.home;
  }

  get configPath(): string {
    return join(this.deps.home, ".cetas", "pi-packages.json");
  }

  get packagesRoot(): string {
    return join(this.deps.home, ".cetas", "pi-packages");
  }

  /** Dispatch `/pi <subcommand> [args]`; bare `/pi` shows the status view. */
  async run(rawArgs: string): Promise<PiCommandOutcome> {
    const tokens = rawArgs.trim().split(/\s+/).filter((token) => token.length > 0);
    if (tokens.length === 0) return this.status(true);
    const [subcommand, ...rest] = tokens;
    switch (subcommand) {
      case "install":
        return this.install(rest.join(" "));
      case "remove":
        return this.remove(rest.join(" "));
      case "list":
        return this.status(false);
      case "help":
        return { ok: true, lines: USAGE.split("\n") };
      default:
        return { ok: false, lines: [`unknown /pi subcommand: ${subcommand}`, USAGE, "hint: /pi help prints this usage"] };
    }
  }

  async install(rawPkg: string): Promise<PiCommandOutcome> {
    const invalid = checkPackageName(rawPkg);
    if (invalid !== undefined) return { ok: false, lines: [invalid] };
    const pkg = rawPkg.trim();
    const snapshot = await this.readSnapshot();
    this.log(`[pi] installing ${pkg} with ${snapshot.npmCommand} ...`);
    const root = await this.ensurePackagesRoot();
    const depsBefore = await umbrellaDependencyNames(root);
    const run = await this.runner()(snapshot.npmCommand, ["add", pkg], root);
    if (run.code !== 0) {
      return { ok: false, lines: [`/pi install ${pkg}: ${snapshot.npmCommand} add exited ${run.code}`, ...tail(run.output)] };
    }
    // Registry specs land under their own name, but local-path/git specs
    // don't: the allowlist needs the manifest name the loader will discover.
    const depsAfter = await umbrellaDependencyNames(root);
    const added = depsAfter.filter((name) => !depsBefore.includes(name));
    const allowName = added.length === 1 ? added[0] : pkg;
    const packages = snapshot.packages.includes(allowName)
      ? snapshot.packages
      : [...snapshot.packages, allowName];
    await this.writeSnapshot(packages, snapshot.raw);
    const summary = await this.deps.reload().catch(() => undefined);
    const lines = [`/pi install ${pkg}: added to the allowlist (${packages.length} configured)`];
    if (allowName !== pkg) lines.push(`allowlisted as ${allowName}`);
    if (summary !== undefined) {
      lines.push(
        `loaded packages: ${(summary.loadedPackages ?? []).length} · new entries loaded: ${summary.entries}`,
      );
      for (const failure of summary.failures) lines.push(`load failure: ${failure}`);
    } else {
      lines.push("package reload unavailable; restart to load it");
    }
    return { ok: true, lines };
  }

  async remove(rawPkg: string): Promise<PiCommandOutcome> {
    const invalid = checkPackageName(rawPkg);
    if (invalid !== undefined) return { ok: false, lines: [invalid] };
    const pkg = rawPkg.trim();
    const snapshot = await this.readSnapshot();
    if (!snapshot.packages.includes(pkg)) {
      return { ok: false, lines: [`/pi remove ${pkg}: not in the allowlist`] };
    }
    this.log(`[pi] removing ${pkg} with ${snapshot.npmCommand} ...`);
    if (!existsSync(this.packagesRoot)) {
      return { ok: false, lines: [`/pi remove ${pkg}: ${this.packagesRoot} does not exist`] };
    }
    const run = await this.runner()(snapshot.npmCommand, ["remove", pkg], this.packagesRoot);
    if (run.code !== 0) {
      return { ok: false, lines: [`/pi remove ${pkg}: ${snapshot.npmCommand} remove exited ${run.code}`, ...tail(run.output)] };
    }
    await this.writeSnapshot(
      snapshot.packages.filter((name) => name !== pkg),
      snapshot.raw,
    );
    return {
      ok: true,
      lines: [
        `/pi remove ${pkg}: removed from the allowlist`,
        "the running agent keeps already-loaded tools; restart required to fully unload",
      ],
    };
  }

  /** `/pi list`: the status view without the usage hint. */
  async list(): Promise<PiCommandOutcome> {
    return this.status(false);
  }

  /**
   * The status view behind bare `/pi` (plus a usage hint) and `/pi list`:
   * each allowlisted package in its activation state, then denied
   * discoveries and loader diagnostics. The summary tracks only an
   * aggregate entry count, so the per-package annotation appears when a
   * single package is loaded and a totals line otherwise.
   */
  private async status(withHint: boolean): Promise<PiCommandOutcome> {
    const hint = withHint ? [USAGE_HINT] : [];
    const snapshot = await this.readSnapshot();
    const summary = this.deps.lastSummary?.();
    if (snapshot.packages.length === 0 && (summary?.skipped?.length ?? 0) === 0) {
      return {
        ok: true,
        lines: [
          "no pi packages configured",
          `(empty or missing ${this.configPath} = deny by default; install with /pi install <pkg>)`,
          ...snapshot.warnings,
          ...hint,
        ],
      };
    }
    const lines: string[] = [];
    const loaded = summary?.loadedPackages ?? [];
    const entries = summary?.entries ?? 0;
    const entriesNote = loaded.length === 1 && entries > 0 ? ` (${entries} ${entries === 1 ? "entry" : "entries"})` : "";
    for (const name of snapshot.packages) {
      if (summary?.loadedPackages?.includes(name) === true) {
        lines.push(`loaded   ${name}${entriesNote}`);
      } else if (summary?.failedPackages?.includes(name) === true) {
        lines.push(`failed   ${name}`);
      } else {
        lines.push(`pending  ${name} (configured; restart or /pi install ${name} to load)`);
      }
    }
    for (const skip of summary?.skipped ?? []) {
      lines.push(`skipped  ${skip.name} (${skip.reason})`);
    }
    if (loaded.length > 1) lines.push(`entries loaded: ${entries} across ${loaded.length} packages`);
    const warningCount = snapshot.warnings.length + (summary?.warnings?.length ?? 0);
    if (warningCount > 0) lines.push(`warnings: ${warningCount}`);
    lines.push(...snapshot.warnings, ...(summary?.warnings ?? []));
    for (const failure of summary?.failures ?? []) lines.push(`load failure: ${failure}`);
    lines.push(...hint);
    return { ok: true, lines };
  }

  private runner(): PiCommandRunner {
    return this.deps.runCommand ?? defaultPiCommandRunner();
  }

  private log(line: string): void {
    (this.deps.log ?? console.log)(line);
  }

  private async readSnapshot(): Promise<Snapshot> {
    let rawText: string | undefined;
    try {
      rawText = await readFile(this.configPath, "utf8");
    } catch {
      rawText = undefined;
    }
    const config = parsePiPackagesConfig(rawText);
    let raw: Record<string, unknown> = {};
    if (rawText !== undefined) {
      try {
        const value: unknown = JSON.parse(rawText);
        if (typeof value === "object" && value !== null && !Array.isArray(value)) {
          raw = value as Record<string, unknown>;
        }
      } catch {
        // Rewrite from a clean object; parse warnings already cover this.
      }
    }
    return { raw, packages: [...config.packages], npmCommand: config.npmCommand, warnings: config.warnings };
  }

  private async writeSnapshot(packages: readonly string[], raw: Record<string, unknown>): Promise<void> {
    await mkdir(join(this.deps.home, ".cetas"), { recursive: true });
    const next = { ...raw, packages: [...packages] };
    await writeFile(this.configPath, `${JSON.stringify(next, null, 2)}\n`);
  }

  /** Create the umbrella directory with its minimal manifest when absent. */
  private async ensurePackagesRoot(): Promise<string> {
    const root = this.packagesRoot;
    await mkdir(root, { recursive: true });
    const manifestPath = join(root, "package.json");
    if (!existsSync(manifestPath)) {
      await writeFile(manifestPath, `${JSON.stringify(UMBRELLA_PACKAGE_JSON)}\n`);
    }
    return root;
  }
}

function checkPackageName(rawPkg: string): string | undefined {
  const pkg = rawPkg.trim();
  if (pkg.length === 0) return "usage: /pi install <pkg> | /pi remove <pkg>";
  if (!PI_PACKAGE_NAME_PATTERN.test(pkg)) {
    return `invalid package name: ${pkg}`;
  }
  return undefined;
}

/** Dependency names declared by the umbrella manifest (empty when unreadable). */
async function umbrellaDependencyNames(root: string): Promise<string[]> {
  try {
    const manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8")) as {
      dependencies?: Record<string, unknown>;
    };
    return Object.keys(manifest.dependencies ?? {});
  } catch {
    return [];
  }
}

function tail(output: string, maxLines = 8): string[] {
  const lines = output.split("\n").filter((line) => line.trim().length > 0);
  return lines.length === 0 ? [] : lines.slice(-maxLines).map((line) => `  ${line}`);
}

/**
 * Argument completion for `/pi …` (sync — the shell's "/" trigger fetch is
 * sync): subcommands first, then allowlisted package names for install/remove.
 */
export function piCommandArgItems(
  home: string,
  argPrefix: string,
): Array<{ label: string; detail: string; insert_text: string }> {
  const spaceIndex = argPrefix.indexOf(" ");
  if (spaceIndex === -1) {
    return [
      ["install", "Install a pi package and allowlist it"],
      ["remove", "Remove a pi package from disk and allowlist"],
      ["list", "Show loaded / skipped / failed pi packages"],
      ["help", "Show the /pi usage"],
    ]
      .filter(([name]) => name.startsWith(argPrefix))
      .map(([name, detail]) => ({ label: name, detail, insert_text: `/pi ${name}` }));
  }
  const subcommand = argPrefix.slice(0, spaceIndex);
  if (subcommand !== "install" && subcommand !== "remove") return [];
  const pkgPrefix = argPrefix.slice(spaceIndex + 1);
  let packages: readonly string[] = [];
  try {
    packages = parsePiPackagesConfig(readFileSync(join(home, ".cetas", "pi-packages.json"), "utf8")).packages;
  } catch {
    return [];
  }
  return packages
    .filter((name) => name.startsWith(pkgPrefix))
    .map((name) => ({
      label: name,
      detail: "pi package in the allowlist",
      insert_text: `/pi ${subcommand} ${name}`,
    }));
}
