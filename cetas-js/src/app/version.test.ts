import { describe, expect, test } from "bun:test";

import { bunGlobalRoot, classifyChannel, cetasVersion, matchGlobalManager } from "./version.ts";

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

  test("package-manager global installs take the npm channel", () => {
    expect(
      classifyChannel(
        "1.4.2",
        "/home/u/.bun/install/global/node_modules/@posoco/cetas/dist/cetas.js",
        {},
        "/home/u",
      ),
    ).toBe("npm");
    expect(
      classifyChannel(
        "1.4.2",
        "/home/u/.local/share/pnpm/global/5/node_modules/@posoco/cetas/dist/cetas.js",
      ),
    ).toBe("npm");
  });
});

describe("matchGlobalManager", () => {
  const env = {};
  const home = "/home/u";

  test("bun's global root (with $BUN_INSTALL override) owns the entry", () => {
    const under = (root: string, rest: string) => matchGlobalManager(`${root}/${rest}`, env, home);
    expect(under(bunGlobalRoot(env, home), "@posoco/cetas/dist/cetas.js")).toBe("bun");
    expect(under("/opt/bun/install/global/node_modules", "x.js")).toBeUndefined();
    expect(
      matchGlobalManager("/opt/bun/install/global/node_modules/x.js", { BUN_INSTALL: "/opt/bun" }, home),
    ).toBe("bun");
  });

  test("pnpm's global root layout is recognized", () => {
    expect(
      matchGlobalManager("/home/u/.local/share/pnpm/global/5/node_modules/@posoco/cetas/dist/cetas.js", env, home),
    ).toBe("pnpm");
    expect(matchGlobalManager("/opt/pnpm/global/5/node_modules/x.js", env, home)).toBe("pnpm");
  });

  test("npm global trees and source checkouts fall back to the npm manager", () => {
    expect(matchGlobalManager("/usr/local/lib/node_modules/@posoco/cetas/dist/cetas.js", env, home)).toBeUndefined();
    expect(matchGlobalManager("/home/dev/cetas/cetas-js/host.ts", env, home)).toBeUndefined();
  });

  test("windows separators normalize", () => {
    expect(
      matchGlobalManager(
        "C:\\Users\\u\\.bun\\install\\global\\node_modules\\@posoco\\cetas\\dist\\cetas.js",
        env,
        "C:\\Users\\u",
      ),
    ).toBe("bun");
  });
});

describe("cetasVersion", () => {
  test("dev fallback reads the real package.json next to the source", () => {
    // Bundled builds get __CETAS_VERSION__ injected; unbundled, the fallback
    // path resolves cetas-js/package.json from src/app.
    expect(cetasVersion()).toMatch(/^(\d+\.\d+\.\d+|dev)$/);
  });
});
