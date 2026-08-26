import { homedir } from "node:os";

import { describe, expect, test } from "bun:test";

import { buildCetasHostConfig } from "./host-config.ts";
import { projectSessionsDir } from "./session-id.ts";

describe("buildCetasHostConfig", () => {
  test("defaults mirror the interactive host wiring", () => {
    const config = buildCetasHostConfig();
    expect(config.cwd).toBe(process.cwd());
    expect(config.home).toBe(homedir());
    expect(config.maxToolRounds).toBe(0);
    expect(config.sessionsDir).toBe(
      projectSessionsDir(config.home, config.cwd),
    );
    expect(config.permissionMode).toBeUndefined();
  });

  test("overrides replace defaults and re-derive the sessions layout", () => {
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
      sessionsDir: "/tmp/home/.cetas/sessions/--tmp-proj--",
    });
  });

  test("explicit sessionsDir wins over the derived per-project layout", () => {
    const config = buildCetasHostConfig({ sessionsDir: "/custom/sessions" });
    expect(config.sessionsDir).toBe("/custom/sessions");
  });
});
