import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import type { Channel, PackageManager } from "./version.ts";

const NPM_PACKAGE = "@posoco/cetas";
const DEFAULT_REGISTRY = "https://registry.npmjs.org";
const RELEASES_LATEST_URL = "https://github.com/colmugx/cetas/releases/latest";
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 3000;
const NPM_CONFIG_TIMEOUT_MS = 3000;
const RELEASE_TAG_RE = /\/tag\/cetas-v(\d+\.\d+\.\d+)\/?$/;
const SEMVER_RE = /^v?(\d+)\.(\d+)\.(\d+)$/;
const BUNFIG_REGISTRY_RE = /^\s*registry\s*=\s*["']([^"']+)["']/m;

/** Structural subset of fetch the checker needs; injectable for tests. */
export type FetchImpl = (
  url: string,
  init?: { signal?: AbortSignal },
) => Promise<{ ok: boolean; url: string; json(): Promise<unknown> }>;

/** Spawn seam for `npm config get registry`; injectable for tests. */
export type CommandRunner = (
  command: string,
  args: readonly string[],
  timeoutMs: number,
) => Promise<{ exitCode: number; stdout: string }>;

const defaultCommandRunner: CommandRunner = (command, args, timeoutMs) =>
  new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    const timer = setTimeout(() => child.kill(), timeoutMs);
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ exitCode: 1, stdout: "" });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ exitCode: code ?? 1, stdout });
    });
  });

function sanitizedRegistry(value: string | undefined): string | undefined {
  const trimmed = value?.trim().replace(/\/+$/, "");
  return trimmed !== undefined && trimmed !== "" && /^https?:\/\//.test(trimmed)
    ? trimmed
    : undefined;
}

/**
 * The registry the user's package manager actually installs from. Mirrors may
 * lag npmjs, so querying the install source keeps every advertised version
 * installable by the very command the /update flow runs.
 */
export async function resolveRegistry(options: {
  manager: PackageManager;
  env: Record<string, string | undefined>;
  home: string;
  runCommand?: CommandRunner;
}): Promise<string> {
  const fromEnv =
    sanitizedRegistry(options.env.CETAS_REGISTRY) ??
    sanitizedRegistry(options.env.npm_config_registry) ??
    sanitizedRegistry(options.env.NPM_CONFIG_REGISTRY);
  if (fromEnv !== undefined) return fromEnv;
  if (options.manager === "bun") {
    // bun does not read .npmrc; its registry lives in ~/.bunfig.toml.
    try {
      const bunfig = await readFile(join(options.home, ".bunfig.toml"), "utf8");
      return sanitizedRegistry(BUNFIG_REGISTRY_RE.exec(bunfig)?.[1]) ?? DEFAULT_REGISTRY;
    } catch {
      return DEFAULT_REGISTRY;
    }
  }
  const run = options.runCommand ?? defaultCommandRunner;
  const result = await run("npm", ["config", "get", "registry"], NPM_CONFIG_TIMEOUT_MS);
  return sanitizedRegistry(result.stdout) ?? DEFAULT_REGISTRY;
}

export interface UpdateHit {
  latest: string;
  url: string;
}

function parseSemver(value: string): [number, number, number] | undefined {
  const match = SEMVER_RE.exec(value.trim());
  if (match === null) return undefined;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

/** Either side failing to parse (including current="dev") means: never nag. */
export function isNewerVersion(current: string, candidate: string): boolean {
  const a = parseSemver(current);
  const b = parseSemver(candidate);
  if (a === undefined || b === undefined) return false;
  return b[0] !== a[0] ? b[0] > a[0] : b[1] !== a[1] ? b[1] > a[1] : b[2] > a[2];
}

function channelHomeUrl(channel: Channel): string {
  return channel === "npm"
    ? `https://www.npmjs.com/package/${NPM_PACKAGE}`
    : RELEASES_LATEST_URL;
}

/** Manager-specific global install command surfaced by the /update picker. */
export function updateInstallCommand(manager: PackageManager): string {
  const install = manager === "npm" ? "npm install -g" : `${manager} add -g`;
  return `${install} ${NPM_PACKAGE}@latest`;
}

/**
 * POSIX one-liner behind "Update now": install, then re-exec cetas through
 * the original argv so the shell hands the terminal straight back.
 */
export function updateHandoffCommand(
  installCommand: string,
  argv: readonly string[],
): string {
  const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
  return `${installCommand} && exec ${argv.map(quote).join(" ")}`;
}

/**
 * Update sources are channel-scoped: the npm publish is manual and lags
 * releases, so a cross-channel comparison would nag users who are current.
 */
async function fetchLatest(
  channel: Channel,
  fetchImpl: FetchImpl,
  registryUrl: string,
): Promise<UpdateHit | undefined> {
  try {
    if (channel === "npm") {
      const res = await fetchImpl(`${registryUrl}/@posoco%2Fcetas/latest`, {
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
      if (!res.ok) return undefined;
      const doc = (await res.json()) as { version?: unknown };
      return typeof doc.version === "string"
        ? { latest: doc.version, url: channelHomeUrl(channel) }
        : undefined;
    }
    const res = await fetchImpl(RELEASES_LATEST_URL, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    const match = RELEASE_TAG_RE.exec(res.url);
    return match === null ? undefined : { latest: match[1], url: channelHomeUrl(channel) };
  } catch {
    return undefined;
  }
}

interface UpdateCheckCache {
  checkedAt: number;
  latest: string;
  channel: string;
}

async function readCache(path: string): Promise<UpdateCheckCache | undefined> {
  try {
    const doc = JSON.parse(await readFile(path, "utf8")) as UpdateCheckCache;
    if (
      typeof doc.checkedAt !== "number" ||
      typeof doc.latest !== "string" ||
      typeof doc.channel !== "string"
    ) {
      return undefined;
    }
    return doc;
  } catch {
    return undefined;
  }
}

async function writeCache(path: string, cache: UpdateCheckCache): Promise<void> {
  try {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, JSON.stringify(cache));
  } catch {
    // The cache is best-effort; a failed write only costs a re-check tomorrow.
  }
}

export interface RunUpdateCheckOptions {
  home: string;
  channel: Channel;
  currentVersion: string;
  /** Owner of the npm-channel install; resolves whose registry to query. */
  manager?: PackageManager;
  /** Skip the 24h cache and hit the update source right now (/update). */
  bypassCache?: boolean;
  now?: () => number;
  fetchImpl?: FetchImpl;
  runCommand?: CommandRunner;
  cachePath?: string;
  env?: Record<string, string | undefined>;
}

/**
 * Returns a hit only when a newer version exists on the channel's own update
 * source. Checked at most once per 24h (cache under `<home>/.cetas/`), never
 * throws, and is silent for the dev channel.
 */
export async function runUpdateCheck(
  options: RunUpdateCheckOptions,
): Promise<UpdateHit | undefined> {
  const now = options.now ?? Date.now;
  const fetchImpl = options.fetchImpl ?? fetch;
  const env = options.env ?? process.env;
  const cachePath =
    options.cachePath ?? join(options.home, ".cetas", "update-check.json");
  if (options.channel === "dev") return undefined;

  const cache = options.bypassCache === true ? undefined : await readCache(cachePath);
  let hit: UpdateHit | undefined;
  if (
    cache !== undefined &&
    cache.channel === options.channel &&
    now() - cache.checkedAt < CHECK_INTERVAL_MS
  ) {
    hit = { latest: cache.latest, url: channelHomeUrl(options.channel) };
  } else {
    const registry =
      options.channel === "npm"
        ? await resolveRegistry({
            manager: options.manager ?? "npm",
            env,
            home: options.home,
            runCommand: options.runCommand,
          })
        : DEFAULT_REGISTRY;
    const fresh = await fetchLatest(options.channel, fetchImpl, registry);
    if (fresh !== undefined) {
      await writeCache(cachePath, {
        checkedAt: now(),
        latest: fresh.latest,
        channel: options.channel,
      });
      hit = fresh;
    }
  }
  if (hit === undefined || !isNewerVersion(options.currentVersion, hit.latest)) {
    return undefined;
  }
  return hit;
}

export function updateNoticeMessage(
  currentVersion: string,
  hit: UpdateHit,
  channel: Channel,
): string {
  const head = `⚠ Update available: cetas ${hit.latest} (current ${currentVersion}, ${channel})`;
  if (channel === "npm") {
    return `${head} — run /update`;
  }
  return `${head} — ${RELEASES_LATEST_URL} (replace the cetas-bun binary and its native/ directory)`;
}

export { DEFAULT_REGISTRY };
