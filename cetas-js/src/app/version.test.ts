import { describe, expect, test } from "bun:test";

import { classifyChannel, cetasVersion } from "./version.ts";

describe("channel classification", () => {
  test("compiled bun executables mount the entry under /$bunfs", () => {
    expect(classifyChannel("1.4.2", "/$bunfs/root/cetas-bun")).toBe("release");
  });

  test("a plain bun run reports the real source path", () => {
    expect(classifyChannel("1.4.2", "/home/dev/cetas/cetas-js/host.ts")).toBe("dev");
  });

  test("no bun runtime means the npm node bundle", () => {
    expect(classifyChannel(undefined, undefined)).toBe("npm");
    expect(classifyChannel(undefined, "/anything")).toBe("npm");
  });
});

describe("cetasVersion", () => {
  test("dev fallback reads the real package.json next to the source", () => {
    // Bundled builds get __CETAS_VERSION__ injected; unbundled, the fallback
    // path resolves cetas-js/package.json from src/app.
    expect(cetasVersion()).toMatch(/^(\d+\.\d+\.\d+|dev)$/);
  });
});
