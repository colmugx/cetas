import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { bootstrapSettings } from "./settings-bootstrap.ts";

let homes: string[] = [];

async function newHome(): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), "cetas-js-bootstrap-"));
  homes.push(home);
  return home;
}

afterEach(async () => {
  for (const home of homes) await rm(home, { recursive: true, force: true });
  homes = [];
});

describe("JS first-run settings bootstrap", () => {
  test("creates a complete minimal settings file when .cetas is absent", async () => {
    const home = await newHome();
    expect(await bootstrapSettings(home)).toBe(true);
    const dir = join(home, ".cetas");
    expect(await readFile(join(dir, "settings.json"), "utf8")).toBe('{"providers":{}}\n');
    expect(await readdir(dir)).toEqual(["settings.json"]);
  });

  test("is idempotent and keeps existing provider and model settings", async () => {
    const home = await newHome();
    const dir = join(home, ".cetas");
    await mkdir(dir);
    const settings = '{"providers":{"deepseek":{}},"model":"deepseek/deepseek-chat"}\n';
    await writeFile(join(dir, "settings.json"), settings);
    expect(await bootstrapSettings(home)).toBe(false);
    expect(await bootstrapSettings(home)).toBe(false);
    expect(await readFile(join(dir, "settings.json"), "utf8")).toBe(settings);
  });

  test("never overwrites an existing empty or malformed settings file", async () => {
    for (const settings of ["", "{invalid"]) {
      const home = await newHome();
      const dir = join(home, ".cetas");
      await mkdir(dir);
      await writeFile(join(dir, "settings.json"), settings);
      expect(await bootstrapSettings(home)).toBe(false);
      expect(await readFile(join(dir, "settings.json"), "utf8")).toBe(settings);
    }
  });

  test("concurrent first starts publish only one complete file", async () => {
    const home = await newHome();
    const results = await Promise.all(Array.from({ length: 24 }, () => bootstrapSettings(home)));
    expect(results.filter(Boolean)).toHaveLength(1);
    const dir = join(home, ".cetas");
    const settings = await readFile(join(dir, "settings.json"), "utf8");
    expect(JSON.parse(settings)).toEqual({ providers: {} });
    expect(await readdir(dir)).toEqual(["settings.json"]);
  });

  if (process.platform !== "win32") {
    test("does not follow or replace an existing dangling settings symlink", async () => {
      const home = await newHome();
      const dir = join(home, ".cetas");
      await mkdir(dir);
      await symlink("absent-config.json", join(dir, "settings.json"));
      expect(await bootstrapSettings(home)).toBe(false);
      expect(await readdir(dir)).toEqual(["settings.json"]);
    });
  }
});
