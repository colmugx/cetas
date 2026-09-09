import { homedir } from "node:os";

import { describe, expect, test } from "bun:test";

import { buildCetasHostConfig } from "./host-config.ts";

describe("buildCetasHostConfig", () => {
  test("defaults mirror the interactive host wiring", () => {
    const config = buildCetasHostConfig();
    expect(config.cwd).toBe(process.cwd());
    expect(config.home).toBe(homedir());
    expect(config.maxToolRounds).toBe(0);
    // The sessions layout is left unset so the MoonBit config resolves the
    // per-project bucket itself (TypeScript never re-derives the name).
    expect(config.sessionsDir).toBeUndefined();
    expect(config.permissionMode).toBeUndefined();
  });

  test("overrides replace defaults", () => {
    const config = buildCetasHostConfig({
      cwd: "/tmp/proj",
      home: "/tmp/home",
      maxToolRounds: 5,
      permissionMode: "readonly",
    });
    expect(config).toEqual({
      cwd: "/tmp/proj",
      maxToolRounds: 5,
      home: "/tmp/home",
      permissionMode: "readonly",
    });
  });

  test("explicit sessionsDir passes through unchanged", () => {
    const config = buildCetasHostConfig({ sessionsDir: "/custom/sessions" });
    expect(config.sessionsDir).toBe("/custom/sessions");
  });
});
