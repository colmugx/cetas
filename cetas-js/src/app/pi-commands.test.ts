import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";

import {
  defaultPiCommandRunner,
  piCommandArgItems,
  PiCommands,
  type PiCommandRunner,
} from "./pi-commands.ts";
import { scanAndLoadPiPackages } from "./pi-packages.ts";

function fakeHome(): string {
  return mkdtempSync(join(tmpdir(), "pi-cmds-home-"));
}

function seedConfig(home: string, value: Record<string, unknown>): void {
  mkdirSync(join(home, ".cetas"), { recursive: true });
  writeFileSync(join(home, ".cetas", "pi-packages.json"), JSON.stringify(value));
}

function stubRunner(code = 0, output = ""): PiCommandRunner & { calls: Array<{ command: string; args: readonly string[]; cwd: string }> } {
  const calls: Array<{ command: string; args: readonly string[]; cwd: string }> = [];
  const run = async (command: string, args: readonly string[], cwd: string) => {
    calls.push({ command, args, cwd });
    return { code, output };
  };
  return Object.assign(run, { calls });
}

describe("PiCommands unit (injectable runner)", () => {
  test("bare /pi shows the status view; /pi help prints usage; unknown subcommand fails", async () => {
    const cmds = new PiCommands({ home: fakeHome(), reload: async () => undefined });
    const bare = await cmds.run("");
    expect(bare.ok).toBe(true);
    const bareText = bare.lines.join("\n");
    expect(bareText).toContain("deny by default");
    expect(bareText).toContain("usage: /pi install|remove|list|help");

    const help = await cmds.run("help");
    expect(help.ok).toBe(true);
    const helpText = help.lines.join("\n");
    expect(helpText).toContain("/pi install <pkg>");
    expect(helpText).toContain("/pi list");

    const unknown = await cmds.run("upgrade something");
    expect(unknown.ok).toBe(false);
    expect(unknown.lines[0]).toContain("unknown /pi subcommand: upgrade");
    expect(unknown.lines.join("\n")).toContain("hint: /pi help prints this usage");
  });

  test("bare /pi renders the status view for one loaded and one skipped package", async () => {
    const home = fakeHome();
    seedConfig(home, { packages: ["loaded-one"] });
    const cmds = new PiCommands({
      home,
      reload: async () => undefined,
      lastSummary: () => ({
        packages: 1,
        entries: 2,
        failures: [],
        loadedPackages: ["loaded-one"],
        skipped: [{ name: "skip-one", reason: "not in allowlist" }],
        warnings: ["mirror note"],
      }),
    });
    const outcome = await cmds.run("");
    expect(outcome.ok).toBe(true);
    const text = outcome.lines.join("\n");
    expect(text).toContain("loaded   loaded-one (2 entries)");
    expect(text).toContain("skipped  skip-one (not in allowlist)");
    expect(text).toContain("warnings: 1");
    expect(text).toContain("mirror note");
    expect(outcome.lines[outcome.lines.length - 1]).toBe("usage: /pi install|remove|list|help");
  });

  test("invalid package names never reach the package manager", async () => {
    const home = fakeHome();
    const runner = stubRunner();
    const cmds = new PiCommands({ home, reload: async () => undefined, runCommand: runner });
    for (const bad of ["", "a b", "pkg;rm", "pkg$(x)", "pkg\nname", "pkg?name"]) {
      const outcome = await cmds.install(bad);
      expect(outcome.ok).toBe(false);
      expect(outcome.lines[0]).toMatch(/usage:|invalid package name/);
    }
    expect(runner.calls).toHaveLength(0);
    expect(existsSync(join(home, ".cetas", "pi-packages"))).toBe(false);
  });

  test("install spawns the configured pm in the umbrella dir, allowlists, reloads", async () => {
    const home = fakeHome();
    seedConfig(home, { packages: [], npmCommand: "bun" });
    const runner = stubRunner();
    let reloads = 0;
    const cmds = new PiCommands({
      home,
      reload: async () => {
        reloads += 1;
        return { packages: 1, entries: 2, failures: [], loadedPackages: ["pi-web-access"] };
      },
      runCommand: runner,
      log: () => {},
    });
    const outcome = await cmds.install("pi-web-access");
    expect(outcome.ok).toBe(true);
    expect(runner.calls).toHaveLength(1);
    expect(runner.calls[0].command).toBe("bun");
    expect(runner.calls[0].args).toEqual(["add", "pi-web-access"]);
    expect(runner.calls[0].cwd).toBe(join(home, ".cetas", "pi-packages"));
    expect(reloads).toBe(1);
    // Umbrella bootstrap manifest exists for the package manager.
    const umbrella = JSON.parse(readFileSync(join(home, ".cetas", "pi-packages", "package.json"), "utf8"));
    expect(umbrella).toEqual({ name: "cetas-pi-packages", private: true, type: "module" });
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual(["pi-web-access"]);
    expect(outcome.lines.join("\n")).toContain("new entries loaded: 2");
  });

  test("install without a snapshot file defaults the pm to npm", async () => {
    const home = fakeHome();
    const runner = stubRunner();
    const cmds = new PiCommands({ home, reload: async () => undefined, runCommand: runner, log: () => {} });
    await cmds.install("some-pkg");
    expect(runner.calls[0].command).toBe("npm");
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual(["some-pkg"]);
  });

  test("failed spawn leaves the snapshot untouched and skips the reload", async () => {
    const home = fakeHome();
    seedConfig(home, { packages: ["kept"] });
    const runner = stubRunner(1, "npm ERR! not found");
    let reloads = 0;
    const cmds = new PiCommands({
      home,
      reload: async () => {
        reloads += 1;
        return undefined;
      },
      runCommand: runner,
      log: () => {},
    });
    const outcome = await cmds.install("missing-pkg");
    expect(outcome.ok).toBe(false);
    expect(outcome.lines.join("\n")).toContain("exited 1");
    expect(outcome.lines.join("\n")).toContain("not found");
    expect(reloads).toBe(0);
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual(["kept"]);
  });

  test("remove spawns the pm, updates the snapshot, notes restart", async () => {
    const home = fakeHome();
    seedConfig(home, { packages: ["pi-web-access", "other"], npmCommand: "bun" });
    mkdirSync(join(home, ".cetas", "pi-packages"), { recursive: true });
    const runner = stubRunner();
    const cmds = new PiCommands({ home, reload: async () => undefined, runCommand: runner, log: () => {} });
    const outcome = await cmds.remove("pi-web-access");
    expect(outcome.ok).toBe(true);
    expect(runner.calls[0].args).toEqual(["remove", "pi-web-access"]);
    const snapshot = JSON.parse(readFileSync(cmds.configPath, "utf8"));
    expect(snapshot.packages).toEqual(["other"]);
    expect(outcome.lines.join("\n")).toContain("restart required to fully unload");
  });

  test("remove rejects a package that is not allowlisted without spawning", async () => {
    const home = fakeHome();
    const runner = stubRunner();
    const cmds = new PiCommands({ home, reload: async () => undefined, runCommand: runner });
    const outcome = await cmds.remove("ghost");
    expect(outcome.ok).toBe(false);
    expect(outcome.lines[0]).toContain("not in the allowlist");
    expect(runner.calls).toHaveLength(0);
  });

  test("list renders loaded / failed / pending / skipped from snapshot + summary", async () => {
    const home = fakeHome();
    seedConfig(home, { packages: ["loaded-one", "loaded-two", "failed-one", "pending-one"] });
    const cmds = new PiCommands({
      home,
      reload: async () => undefined,
      lastSummary: () => ({
        packages: 2,
        entries: 3,
        failures: ["boom"],
        loadedPackages: ["loaded-one", "loaded-two"],
        failedPackages: ["failed-one"],
        skipped: [{ name: "skip-one", reason: "not in allowlist" }],
      }),
    });
    const outcome = await cmds.list();
    const text = outcome.lines.join("\n");
    expect(text).toContain("loaded   loaded-one");
    expect(text).toContain("loaded   loaded-two");
    expect(text).toContain("entries loaded: 3 across 2 packages");
    expect(text).toContain("failed   failed-one");
    expect(text).toContain("pending  pending-one");
    expect(text).toContain("skipped  skip-one (not in allowlist)");
    expect(text).toContain("load failure: boom");
    expect(text).not.toContain("usage: /pi install|remove|list|help");
  });

  test("list with nothing configured states the deny-by-default rule", async () => {
    const cmds = new PiCommands({ home: fakeHome(), reload: async () => undefined });
    const outcome = await cmds.list();
    expect(outcome.ok).toBe(true);
    expect(outcome.lines.join("\n")).toContain("deny by default");
  });
});

describe("piCommandArgItems", () => {
  test("completes subcommands from the bare command prefix", () => {
    const all = piCommandArgItems(fakeHome(), "");
    expect(all.map((item) => item.label)).toEqual(["install", "remove", "list", "help"]);
    const partial = piCommandArgItems(fakeHome(), "in");
    expect(partial.map((item) => item.label)).toEqual(["install"]);
    expect(partial[0].insert_text).toBe("/pi install");
  });

  test("completes allowlisted package names for install/remove", () => {
    const home = fakeHome();
    seedConfig(home, { packages: ["pi-web-access", "other-pkg"] });
    const items = piCommandArgItems(home, "install pi");
    expect(items).toHaveLength(1);
    expect(items[0]).toEqual({
      label: "pi-web-access",
      detail: "pi package in the allowlist",
      insert_text: "/pi install pi-web-access",
    });
    // list takes no package argument.
    expect(piCommandArgItems(home, "list ")).toEqual([]);
  });

  test("no snapshot file means no package completions", () => {
    expect(piCommandArgItems(fakeHome(), "install ")).toEqual([]);
  });
});

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
