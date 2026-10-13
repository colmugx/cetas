import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import type { Channel } from "./version.ts";

const NPM_PACKAGE = "@posoco/cetas";
const NPM_LATEST_URL = `https://registry.npmjs.org/${NPM_PACKAGE}/latest`;
const RELEASES_LATEST_URL = "https://github.com/colmugx/cetas/releases/latest";
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 3000;
const RELEASE_TAG_RE = /\/tag\/cetas-v(\d+\.\d+\.\d+)\/?$/;
const SEMVER_RE = /^v?(\d+)\.(\d+)\.(\d+)$/;

/** Structural subset of fetch the checker needs; injectable for tests. */
export type FetchImpl = (
  url: string,
  init?: { signal?: AbortSignal },
) => Promise<{ ok: boolean; url: string; json(): Promise<unknown> }>;

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

/**
 * Update sources are channel-scoped: the npm publish is manual and lags
 * releases, so a cross-channel comparison would nag users who are current.
 */
async function fetchLatest(
  channel: Channel,
  fetchImpl: FetchImpl,
): Promise<UpdateHit | undefined> {
  try {
    if (channel === "npm") {
      const res = await fetchImpl(NPM_LATEST_URL, {
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
  now?: () => number;
  fetchImpl?: FetchImpl;
  cachePath?: string;
  env?: Record<string, string | undefined>;
}

/**
 * Returns a hit only when a newer version exists on the channel's own update
 * source. Checked at most once per 24h (cache under `<home>/.cetas/`), never
 * throws, and is silent for the dev channel or `CETAS_NO_UPDATE_CHECK`.
 */
export async function runUpdateCheck(
  options: RunUpdateCheckOptions,
): Promise<UpdateHit | undefined> {
  const now = options.now ?? Date.now;
  const fetchImpl = options.fetchImpl ?? fetch;
  const env = options.env ?? process.env;
  const cachePath =
    options.cachePath ?? join(options.home, ".cetas", "update-check.json");
  const optOut = env.CETAS_NO_UPDATE_CHECK;
  if (optOut !== undefined && optOut !== "" && optOut !== "0") return undefined;
  if (options.channel === "dev") return undefined;

  const cache = await readCache(cachePath);
  let hit: UpdateHit | undefined;
  if (
    cache !== undefined &&
    cache.channel === options.channel &&
    now() - cache.checkedAt < CHECK_INTERVAL_MS
  ) {
    hit = { latest: cache.latest, url: channelHomeUrl(options.channel) };
  } else {
    const fresh = await fetchLatest(options.channel, fetchImpl);
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
    return `${head} — run: npm install -g ${NPM_PACKAGE}`;
  }
  return `${head} — ${RELEASES_LATEST_URL} (replace the cetas-bun binary and its native/ directory)`;
}
