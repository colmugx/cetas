import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";

import {
  DEFAULT_PI_NPM_COMMAND,
  parsePiPackagesConfig,
  readPiPackagesConfig,
  resolvePiPackageManager,
  scanAndLoadPiPackages,
} from "./pi-packages.ts";

describe("parsePiPackagesConfig", () => {
  test("missing file is a silent empty allowlist", () => {
    const config = parsePiPackagesConfig(undefined);
    expect(config.present).toBe(false);
    expect(config.packages).toEqual([]);
    expect(config.npmCommand).toBe(DEFAULT_PI_NPM_COMMAND);
    expect(config.warnings).toEqual([]);
  });

  test("valid snapshot parses packages and npmCommand", () => {
    const config = parsePiPackagesConfig('{"packages":["pi-web-access"],"npmCommand":"bun"}');
    expect(config.present).toBe(true);
    expect(config.packages).toEqual(["pi-web-access"]);
    expect(config.npmCommand).toBe("bun");
    expect(config.warnings).toEqual([]);
  });

  test("malformed JSON degrades to an empty allowlist with a warning", () => {
    const config = parsePiPackagesConfig("{not json");
    expect(config.present).toBe(true);
    expect(config.packages).toEqual([]);
    expect(config.npmCommand).toBe(DEFAULT_PI_NPM_COMMAND);
    expect(config.warnings).toHaveLength(1);
    expect(config.warnings[0]).toContain("not valid JSON");
  });

  test("non-object JSON degrades to an empty allowlist with a warning", () => {
    for (const raw of ['["pi-web-access"]', '"pi-web-access"', "42", "null"]) {
      const config = parsePiPackagesConfig(raw);
      expect(config.present).toBe(true);
      expect(config.packages).toEqual([]);
      expect(config.warnings[0]).toContain("must be a JSON object");
    }
  });

  test("non-array or non-string packages entries are dropped with warnings", () => {
    const config = parsePiPackagesConfig(
      '{"packages":"pi-web-access"}',
    );
    expect(config.packages).toEqual([]);
    expect(config.warnings[0]).toContain("must be an array");

    const mixed = parsePiPackagesConfig('{"packages":["ok", 7, "", "  ", "ok"]}');
    expect(mixed.packages).toEqual(["ok"]);
    expect(mixed.warnings).toHaveLength(3);
  });

  test("readPiPackagesConfig: missing file reports present=false", async () => {
    const config = await readPiPackagesConfig(join(mkdtempSync(tmpdir() + "/pi-cfg-"), "absent.json"));
    expect(config.present).toBe(false);
  });
});

describe("resolvePiPackageManager", () => {
  test("default is npm", () => {
    expect(resolvePiPackageManager(undefined)).toBe("npm");
    expect(resolvePiPackageManager(null)).toBe("npm");
    expect(resolvePiPackageManager("   ")).toBe("npm");
    expect(resolvePiPackageManager(42)).toBe("npm");
    expect(resolvePiPackageManager([])).toBe("npm");
    expect(resolvePiPackageManager(["   ", 7])).toBe("npm");
  });

  test("string wins; array falls back to its first usable entry", () => {
    expect(resolvePiPackageManager("bun")).toBe("bun");
    expect(resolvePiPackageManager(" pnpm ")).toBe("pnpm");
    expect(resolvePiPackageManager(["  ", "yarn", "npm"])).toBe("yarn");
  });
});

describe("scanAndLoadPiPackages allowlist gating", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-packages-gating-"));

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
  });

  const write = (relPath: string, content: string): void => {
    const target = join(root, relPath);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  };

  /** Direct-dir fixture package (secondary layout, no umbrella manifest). */
  function writePackage(name: string, entryFile = "index.js", entrySource = "export default () => {};\n"): void {
    write(`pi-packages/${name}/package.json`, JSON.stringify({ name, pi: { extensions: [`./${entryFile}`] } }));
    write(`pi-packages/${name}/${entryFile}`, entrySource);
  }

  test("missing snapshot file denies ALL packages (empty = deny, no seeding)", async () => {
    writePackage("alpha");
    writePackage("beta");
    const summary = await scanAndLoadPiPackages(
      join(root, "pi-packages"),
      async () => {},
    );
    expect(summary.packages).toBe(0);
    expect(summary.entries).toBe(0);
    expect(summary.skipped).toHaveLength(2);
    expect(summary.skipped?.map((skip) => skip.name).sort()).toEqual(["alpha", "beta"]);
    for (const skip of summary.skipped ?? []) {
      expect(skip.reason).toBe("not in allowlist");
    }
  });

  test("empty packages array denies all as well", async () => {
    write("pi-packages.json", JSON.stringify({ packages: [] }));
    const summary = await scanAndLoadPiPackages(join(root, "pi-packages"), async () => {});
    expect(summary.packages).toBe(0);
    expect(summary.skipped).toHaveLength(2);
  });

  test("allowlist subset loads exactly the named packages", async () => {
    write("pi-packages.json", JSON.stringify({ packages: ["alpha"] }));
    const summary = await scanAndLoadPiPackages(join(root, "pi-packages"), async () => {});
    expect(summary.packages).toBe(1);
    expect(summary.entries).toBe(1);
    expect(summary.loadedPackages).toEqual(["alpha"]);
    expect(summary.skipped?.map((skip) => skip.name)).toEqual(["beta"]);
    expect(summary.failures).toEqual([]);
  });

  test("allowlisted entry failure lands in failedPackages; config warnings ride the summary", async () => {
    writePackage("gamma", "index.js", "export default () => {};\n");
    writePackage("delta", "bad-entry.js");
    write("pi-packages.json", JSON.stringify({ packages: ["gamma", "delta"], npmCommand: "bun" }));
    const summary = await scanAndLoadPiPackages(join(root, "pi-packages"), async (url) => {
      if (url.includes("bad-entry")) throw new Error("entry exploded");
    });
    expect(summary.loadedPackages).toEqual(["gamma"]);
    expect(summary.failedPackages).toEqual(["delta"]);
    expect(summary.failures).toHaveLength(1);
    expect(summary.failures[0]).toContain("entry exploded");
  });
});
