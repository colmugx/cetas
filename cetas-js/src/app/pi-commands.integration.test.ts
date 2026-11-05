import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";

import { defaultPiCommandRunner, PiCommands } from "./pi-commands.ts";
import { scanAndLoadPiPackages } from "./pi-packages.ts";

// Real package-manager execution: belongs to the e2e channel
// (`.integration.test.ts`), not the default unit loop.
describe("PiCommands end to end with the real bun runner", () => {
  const home = mkdtempSync(join(tmpdir(), "pi-cmds-e2e-home-"));
  const fixtureRoot = mkdtempSync(join(tmpdir(), "pi-cmds-e2e-pkg-"));

  afterAll(() => {
    rmSync(home, { recursive: true, force: true });
    rmSync(fixtureRoot, { recursive: true, force: true });
  });

  const fixtureName = "fixture-pi-pkg";
  const fixtureDir = join(fixtureRoot, fixtureName);
  let loadedDefaultIsFunction = false;

  function setupFixture(): void {
    const write = (relPath: string, content: string): void => {
      const target = join(fixtureDir, relPath);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, content);
    };
    write(
      "package.json",
      JSON.stringify({ name: fixtureName, version: "0.0.1", private: true, pi: { extensions: ["./index.mjs"] } }),
    );
    write(
      "index.mjs",
      "export default function fixturePi(pi) {\n  pi.registerTool({ name: \"fixture_tool\", description: \"e2e\", parameters: { type: \"object\", properties: {} }, execute: () => ({ content: [] }) });\n}\n",
    );
  }

  function reloadThroughLoader() {
    const loaded = new Set<string>();
    return scanAndLoadPiPackages(
      cmds.packagesRoot,
      async (entryUrl) => {
        const mod = (await import(entryUrl)) as { default?: unknown };
        loadedDefaultIsFunction = typeof mod.default === "function";
      },
      loaded,
    );
  }

  const cmds = new PiCommands({
    home,
    reload: reloadThroughLoader,
    runCommand: defaultPiCommandRunner(),
    log: () => {},
  });

  test("install of a local directory package: spawn, snapshot, loader load", async () => {
    setupFixture();
    // Pre-seed the pm choice (empty allowlist still denies); bun add accepts
    // an absolute local path and records the manifest name as the dep key.
    mkdirSync(join(home, ".cetas"), { recursive: true });
    writeFileSync(cmds.configPath, JSON.stringify({ packages: [], npmCommand: "bun" }));

    const outcome = await cmds.install(fixtureDir);
    expect(outcome.ok).toBe(true);
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual([fixtureName]);

    const summary = await reloadThroughLoader();
    expect(summary.packages).toBe(1);
    expect(summary.entries).toBe(1);
    expect(summary.loadedPackages).toEqual([fixtureName]);
    expect(summary.failures).toEqual([]);
    expect(loadedDefaultIsFunction).toBe(true);
  }, 120_000);

  test("remove of the local package: spawn, snapshot updated, loader then skips", async () => {
    const outcome = await cmds.remove(fixtureName);
    expect(outcome.ok).toBe(true);
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual([]);

    // bun remove also drops the umbrella dependency, so the loader discovers
    // nothing at all; either way the package must not load.
    const summary = await reloadThroughLoader();
    expect(summary.packages).toBe(0);
    expect(summary.loadedPackages ?? []).toEqual([]);
  }, 120_000);
});
