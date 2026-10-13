import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  isNewerVersion,
  runUpdateCheck,
  updateNoticeMessage,
  type FetchImpl,
} from "./update-check.ts";

const HOME = "current-home";
const CURRENT = "0.8.1";

function stubFetch(
  response: { status?: number; finalUrl?: string; body?: unknown } | Error,
): { impl: FetchImpl; calls: () => number; lastUrl: () => string | undefined } {
  let calls = 0;
  let lastUrl: string | undefined;
  const impl: FetchImpl = (url) => {
    calls += 1;
    lastUrl = url;
    if (response instanceof Error) return Promise.reject(response);
    return Promise.resolve({
      ok: (response.status ?? 200) === 200,
      url: response.finalUrl ?? "",
      json: () => Promise.resolve(response.body),
    });
  };
  return { impl, calls: () => calls, lastUrl: () => lastUrl };
}

let dir: string;
afterEach(async () => {
  if (dir !== undefined) await rm(dir, { recursive: true, force: true });
});

async function tempCachePath(): Promise<string> {
  dir = await mkdtemp(join(tmpdir(), "cetas-update-check-"));
  return join(dir, "update-check.json");
}

describe("isNewerVersion", () => {
  test("strictly newer wins per component", () => {
    expect(isNewerVersion("0.8.1", "0.8.1")).toBe(false);
    expect(isNewerVersion("0.8.1", "0.8.2")).toBe(true);
    expect(isNewerVersion("0.8.1", "0.8.0")).toBe(false);
    expect(isNewerVersion("0.8.9", "0.8.10")).toBe(true);
    expect(isNewerVersion("0.9.0", "1.0.0")).toBe(true);
    expect(isNewerVersion("1.0.0", "0.99.99")).toBe(false);
  });

  test("unparsable input never nags, including the dev fallback", () => {
    expect(isNewerVersion("dev", "9.9.9")).toBe(false);
    expect(isNewerVersion("0.8.1", "not-a-version")).toBe(false);
    expect(isNewerVersion("v0.8.1", "0.8.2")).toBe(true);
  });
});

describe("runUpdateCheck", () => {
  test("opt-out and dev channel short-circuit without any request", async () => {
    const fetcher = stubFetch({ body: { version: "9.9.9" } });
    const cachePath = await tempCachePath();
    expect(
      await runUpdateCheck({
        home: HOME,
        channel: "npm",
        currentVersion: CURRENT,
        fetchImpl: fetcher.impl,
        cachePath,
        env: { CETAS_NO_UPDATE_CHECK: "1" },
      }),
    ).toBeUndefined();
    expect(
      await runUpdateCheck({
        home: HOME,
        channel: "dev",
        currentVersion: CURRENT,
        fetchImpl: fetcher.impl,
        cachePath,
      }),
    ).toBeUndefined();
    expect(fetcher.calls()).toBe(0);
  });

  test("a fresh cache answers without the network", async () => {
    const fetcher = stubFetch({ body: { version: "9.9.9" } });
    const cachePath = await tempCachePath();
    await writeFile(
      cachePath,
      JSON.stringify({ checkedAt: Date.now(), latest: "1.2.3", channel: "npm" }),
    );
    const hit = await runUpdateCheck({
      home: HOME,
      channel: "npm",
      currentVersion: CURRENT,
      fetchImpl: fetcher.impl,
      cachePath,
    });
    expect(fetcher.calls()).toBe(0);
    expect(hit).toEqual({
      latest: "1.2.3",
      url: "https://www.npmjs.com/package/@posoco/cetas",
    });
  });

  test("a fresh cache whose latest is not newer stays silent", async () => {
    const fetcher = stubFetch({ body: { version: "9.9.9" } });
    const cachePath = await tempCachePath();
    await writeFile(
      cachePath,
      JSON.stringify({ checkedAt: Date.now(), latest: "0.8.1", channel: "npm" }),
    );
    expect(
      await runUpdateCheck({
        home: HOME,
        channel: "npm",
        currentVersion: CURRENT,
        fetchImpl: fetcher.impl,
        cachePath,
      }),
    ).toBeUndefined();
  });

  test("a stale cache triggers exactly one fetch and is rewritten", async () => {
    const fetcher = stubFetch({ body: { version: "1.2.3" } });
    const cachePath = await tempCachePath();
    await writeFile(
      cachePath,
      JSON.stringify({ checkedAt: 0, latest: "0.0.1", channel: "npm" }),
    );
    const hit = await runUpdateCheck({
      home: HOME,
      channel: "npm",
      currentVersion: CURRENT,
      fetchImpl: fetcher.impl,
      cachePath,
    });
    expect(fetcher.calls()).toBe(1);
    expect(fetcher.lastUrl()).toBe("https://registry.npmjs.org/@posoco/cetas/latest");
    expect(hit?.latest).toBe("1.2.3");
    const stored = JSON.parse(await readFile(cachePath, "utf8")) as {
      checkedAt: number;
      latest: string;
      channel: string;
    };
    expect(stored.checkedAt).toBeGreaterThan(0);
    expect(stored).toMatchObject({ latest: "1.2.3", channel: "npm" });
  });

  test("the release channel resolves the latest tag from the redirect URL", async () => {
    const fetcher = stubFetch({
      finalUrl: "https://github.com/colmugx/cetas/releases/tag/cetas-v2.3.4",
    });
    const cachePath = await tempCachePath();
    const hit = await runUpdateCheck({
      home: HOME,
      channel: "release",
      currentVersion: CURRENT,
      fetchImpl: fetcher.impl,
      cachePath,
    });
    expect(fetcher.lastUrl()).toBe("https://github.com/colmugx/cetas/releases/latest");
    expect(hit).toEqual({
      latest: "2.3.4",
      url: "https://github.com/colmugx/cetas/releases/latest",
    });
  });

  test("an unrecognized release redirect is silent and never cached", async () => {
    const fetcher = stubFetch({ finalUrl: "https://github.com/colmugx/cetas/releases" });
    const cachePath = await tempCachePath();
    expect(
      await runUpdateCheck({
        home: HOME,
        channel: "release",
        currentVersion: CURRENT,
        fetchImpl: fetcher.impl,
        cachePath,
      }),
    ).toBeUndefined();
    await expect(readFile(cachePath, "utf8")).rejects.toThrow();
  });

  test("a failed or malformed fetch is silent and leaves the old cache alone", async () => {
    const cachePath = await tempCachePath();
    const old = JSON.stringify({ checkedAt: 0, latest: "0.0.1", channel: "npm" });
    await writeFile(cachePath, old);
    for (const response of [new Error("offline"), { status: 503 }, { body: {} }] as const) {
      const fetcher = stubFetch(response);
      expect(
        await runUpdateCheck({
          home: HOME,
          channel: "npm",
          currentVersion: CURRENT,
          fetchImpl: fetcher.impl,
          cachePath,
        }),
      ).toBeUndefined();
      expect(await readFile(cachePath, "utf8")).toBe(old);
    }
  });

  test("a failed cache write still surfaces the hit", async () => {
    const file = await tempCachePath();
    // A regular file where the cache directory should be makes mkdir fail.
    await writeFile(file, "occupied");
    const cachePath = join(file, "cache.json");
    const fetcher = stubFetch({ body: { version: "1.2.3" } });
    const hit = await runUpdateCheck({
      home: HOME,
      channel: "npm",
      currentVersion: CURRENT,
      fetchImpl: fetcher.impl,
      cachePath,
    });
    expect(hit?.latest).toBe("1.2.3");
  });
});

describe("updateNoticeMessage", () => {
  const hit = { latest: "1.2.3", url: "" };
  test("npm copy suggests the npm upgrade command", () => {
    expect(updateNoticeMessage("0.8.1", hit, "npm")).toBe(
      "⚠ Update available: cetas 1.2.3 (current 0.8.1, npm) — run: npm install -g @posoco/cetas",
    );
  });
  test("release copy points at the releases page and the native/ directory", () => {
    expect(updateNoticeMessage("0.8.1", hit, "release")).toBe(
      "⚠ Update available: cetas 1.2.3 (current 0.8.1, release) — https://github.com/colmugx/cetas/releases/latest (replace the cetas-bun binary and its native/ directory)",
    );
  });
});
