import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  DEFAULT_REGISTRY,
  isNewerVersion,
  resolveRegistry,
  runUpdateCheck,
  updateHandoffCommand,
  updateInstallCommand,
  updateNoticeMessage,
  type CommandRunner,
  type FetchImpl,
} from "./update-check.ts";

const HOME = "current-home";
const CURRENT = "0.8.1";

/** Never spawns: every network-reaching runUpdateCheck call must inject this or a stub. */
const noSpawn: CommandRunner = async () => ({ exitCode: 1, stdout: "" });

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
  test("the dev channel short-circuits without any request", async () => {
    const fetcher = stubFetch({ body: { version: "9.9.9" } });
    const cachePath = await tempCachePath();
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
      runCommand: noSpawn,
      cachePath,
    });
    expect(fetcher.calls()).toBe(1);
    expect(fetcher.lastUrl()).toBe("https://registry.npmjs.org/@posoco%2Fcetas/latest");
    expect(hit?.latest).toBe("1.2.3");
    const stored = JSON.parse(await readFile(cachePath, "utf8")) as {
      checkedAt: number;
      latest: string;
      channel: string;
    };
    expect(stored.checkedAt).toBeGreaterThan(0);
    expect(stored).toMatchObject({ latest: "1.2.3", channel: "npm" });
  });

  test("bypassCache refetches even with a fresh cache", async () => {
    const fetcher = stubFetch({ body: { version: "1.2.3" } });
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
      runCommand: noSpawn,
      cachePath,
      bypassCache: true,
    });
    expect(fetcher.calls()).toBe(1);
    expect(hit?.latest).toBe("1.2.3");
  });

  test("the resolved registry hosts the latest lookup", async () => {
    const fetcher = stubFetch({ body: { version: "1.2.3" } });
    const cachePath = await tempCachePath();
    const hit = await runUpdateCheck({
      home: HOME,
      channel: "npm",
      currentVersion: CURRENT,
      fetchImpl: fetcher.impl,
      runCommand: noSpawn,
      cachePath,
      env: { npm_config_registry: "https://registry.npmmirror.com" },
    });
    expect(fetcher.lastUrl()).toBe(
      "https://registry.npmmirror.com/@posoco%2Fcetas/latest",
    );
    expect(hit?.latest).toBe("1.2.3");
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
          runCommand: noSpawn,
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
      runCommand: noSpawn,
      cachePath,
    });
    expect(hit?.latest).toBe("1.2.3");
  });
});

describe("resolveRegistry", () => {
  const base = { manager: "npm" as const, env: {}, home: HOME };

  test("the explicit override wins and trailing slashes trim", async () => {
    expect(
      await resolveRegistry({ ...base, env: { CETAS_REGISTRY: "https://mirror.example/" } }),
    ).toBe("https://mirror.example");
  });

  test("npm environment config is honored; non-http URLs are rejected", async () => {
    expect(
      await resolveRegistry({ ...base, env: { npm_config_registry: "https://reg.a.example" } }),
    ).toBe("https://reg.a.example");
    expect(
      await resolveRegistry({
        ...base,
        env: { NPM_CONFIG_REGISTRY: "file:///local" },
        runCommand: noSpawn,
      }),
    ).toBe(DEFAULT_REGISTRY);
  });

  test("bun resolves via ~/.bunfig.toml without spawning npm", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cetas-bunfig-"));
    try {
      await writeFile(join(dir, ".bunfig.toml"), '[install]\nregistry = "https://reg.bun.example"\n');
      let spawned = false;
      expect(
        await resolveRegistry({
          manager: "bun",
          env: {},
          home: dir,
          runCommand: async () => {
            spawned = true;
            return { exitCode: 0, stdout: "" };
          },
        }),
      ).toBe("https://reg.bun.example");
      expect(spawned).toBe(false);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("bun without a bunfig registry falls back to the default", async () => {
    expect(
      await resolveRegistry({
        manager: "bun",
        env: {},
        home: HOME,
        runCommand: async () => {
          throw new Error("bun resolves must not spawn npm");
        },
      }),
    ).toBe(DEFAULT_REGISTRY);
  });

  test("npm and pnpm query npm config and trim its stdout", async () => {
    const runCommand: CommandRunner = async () => ({
      exitCode: 0,
      stdout: "https://registry.npmmirror.com/\n",
    });
    expect(await resolveRegistry({ ...base, runCommand })).toBe("https://registry.npmmirror.com");
    expect(await resolveRegistry({ ...base, manager: "pnpm", runCommand })).toBe(
      "https://registry.npmmirror.com",
    );
  });

  test("a failed or non-http npm config answer falls back to the default", async () => {
    expect(
      await resolveRegistry({ ...base, runCommand: async () => ({ exitCode: 1, stdout: "" }) }),
    ).toBe(DEFAULT_REGISTRY);
    expect(
      await resolveRegistry({
        ...base,
        runCommand: async () => ({ exitCode: 0, stdout: "not a url" }),
      }),
    ).toBe(DEFAULT_REGISTRY);
  });
});

describe("updateInstallCommand", () => {
  test("manager-specific global install commands", () => {
    expect(updateInstallCommand("npm")).toBe("npm install -g @posoco/cetas@latest");
    expect(updateInstallCommand("pnpm")).toBe("pnpm add -g @posoco/cetas@latest");
    expect(updateInstallCommand("bun")).toBe("bun add -g @posoco/cetas@latest");
  });
});

describe("updateHandoffCommand", () => {
  test("installs then re-execs the original argv", () => {
    expect(updateHandoffCommand("bun add -g @posoco/cetas@latest", ["/usr/bin/env", "bun", "/x/cetas"])).toBe(
      "bun add -g @posoco/cetas@latest && exec '/usr/bin/env' 'bun' '/x/cetas'",
    );
  });

  test("single quotes survive POSIX escaping", () => {
    expect(updateHandoffCommand("npm i", ["node", "/a'b/c"])).toBe(
      "npm i && exec 'node' '/a'\\''b/c'",
    );
  });
});

describe("updateNoticeMessage", () => {
  const hit = { latest: "1.2.3", url: "" };
  test("npm copy points at the /update command", () => {
    expect(updateNoticeMessage("0.8.1", hit, "npm")).toBe(
      "⚠ Update available: cetas 1.2.3 (current 0.8.1, npm) — run /update",
    );
  });
  test("release copy points at the releases page and the native/ directory", () => {
    expect(updateNoticeMessage("0.8.1", hit, "release")).toBe(
      "⚠ Update available: cetas 1.2.3 (current 0.8.1, release) — https://github.com/colmugx/cetas/releases/latest (replace the cetas-bun binary and its native/ directory)",
    );
  });
});
