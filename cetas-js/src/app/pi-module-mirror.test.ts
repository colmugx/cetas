import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, describe, expect, test } from "bun:test";

import { PiModuleMirror, resolvePiEntryFile } from "./pi-module-mirror.ts";
import { scanAndLoadPiPackages } from "./pi-packages.ts";

// Synthetic node_modules fixtures (never the real ~/.cetas): each dependency
// exercises one resolution form the mirror must support.
function buildFixtureTree(root: string): void {
  const write = (relPath: string, content: string): void => {
    const target = join(root, relPath);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  };

  write("rel-helper.ts", `export const twin = "ts-twin";\n`);

  write("node_modules/plain/package.json", JSON.stringify({ name: "plain", main: "./lib/entry.js" }));
  write(
    "node_modules/plain/lib/entry.js",
    `import { tool } from "./util.js";\nexport const plainMain = "plain-main";\nexport { tool };\n`,
  );
  write("node_modules/plain/lib/util.js", `export const tool = "plain-tool";\n`);

  write("node_modules/plain2/package.json", JSON.stringify({ name: "plain2", main: "./main.js" }));
  write("node_modules/plain2/main.js", `export const main = "plain2-main";\n`);
  write("node_modules/plain2/extra.js", `export const extra = "plain2-extra";\n`);

  write(
    "node_modules/cond/package.json",
    JSON.stringify({
      name: "cond",
      exports: {
        ".": {
          types: "./types.d.ts",
          require: "./cjs.cjs",
          import: "./esm.mjs",
        },
      },
    }),
  );
  write("node_modules/cond/types.d.ts", `export declare const cond: string;\n`);
  write("node_modules/cond/cjs.cjs", `module.exports = { cond: "cjs" };\n`);
  write(
    "node_modules/cond/esm.mjs",
    `import { tmpdir } from "os";\nexport const cond = "esm";\nexport const osTmpKind = typeof tmpdir;\n`,
  );

  write(
    "node_modules/wild/package.json",
    JSON.stringify({
      name: "wild",
      exports: { "./feat/*": "./src/feat/*.js", "./gone/*": "./missing/*.js" },
    }),
  );
  write("node_modules/wild/src/feat/one.js", `export const feature = "wild-one";\n`);

  write(
    "node_modules/@scoped/peer/package.json",
    JSON.stringify({ name: "@scoped/peer", exports: { ".": "./index.js" } }),
  );
  write("node_modules/@scoped/peer/index.js", `export const peer = "scoped-peer";\n`);

  write(
    "node_modules/chalklike/package.json",
    JSON.stringify({
      name: "chalklike",
      main: "./source/index.js",
      imports: { "#internal": "./source/internal.js", "#feat/*": "./src/feat/*.js" },
    }),
  );
  write(
    "node_modules/chalklike/source/index.js",
    `import { shade } from "#internal";\nimport { feat } from "#feat/one";\nimport { peer } from "@scoped/peer";\nexport { shade, feat, peer };\n`,
  );
  write("node_modules/chalklike/source/internal.js", `export const shade = "internal-shade";\n`);
  write("node_modules/chalklike/src/feat/one.js", `export const feat = "feat-one";\n`);

  write("node_modules/jsony/package.json", JSON.stringify({ name: "jsony", main: "./index.js" }));
  write("node_modules/jsony/index.js", `import config from "./config.json";\nexport const label = config.label;\n`);
  write("node_modules/jsony/config.json", JSON.stringify({ label: "jsony-label" }));

  write("node_modules/requirey/package.json", JSON.stringify({ name: "requirey", main: "./index.js" }));
  write(
    "node_modules/requirey/index.js",
    `import { createRequire } from "node:module";\nconst require = createRequire(import.meta.url);\nexport const value = require("./impl.cjs");\n`,
  );
  write("node_modules/requirey/impl.cjs", `module.exports = "cjs-impl";\n`);

  write("node_modules/optional/package.json", JSON.stringify({ name: "optional", main: "./index.js" }));
  write(
    "node_modules/optional/index.js",
    `let mod;\ntry { mod = (await import("canvas")).default; } catch {}\nexport const hasCanvas = mod != null;\n`,
  );

  write("node_modules/attrjson/package.json", JSON.stringify({ name: "attrjson", main: "./index.js" }));
  write(
    "node_modules/attrjson/index.js",
    `import values from "./data.json" with { type: "json" };\nexport const count = values.count;\n`,
  );
  write("node_modules/attrjson/data.json", JSON.stringify({ count: 7 }));

  write("node_modules/cyc/package.json", JSON.stringify({ name: "cyc", main: "./a.js" }));
  write("node_modules/cyc/a.js", `import { b } from "./b.js";\nexport const a = "a" + b;\n`);
  write("node_modules/cyc/b.js", `import "./a.js";\nexport const b = "b";\n`);

  // pi-coding-agent 0.84.4 regression: an export clause carrying inline
  // comments with parentheses must not hide "./core/sdk.js" from the scan.
  write("node_modules/clausey/package.json", JSON.stringify({ name: "clausey", main: "./index.js" }));
  write(
    "node_modules/clausey/index.js",
    [
      `export { sdkValue,`,
      `// Factory`,
      `sdkHelper,`,
      `// Tool factories (for custom cwd)`,
      `sdkTool, } from "./core/sdk.js";`,
      `export const local = "clausey-local";`,
    ].join("\n") + "\n",
  );
  write(
    "node_modules/clausey/core/sdk.js",
    `export const sdkValue = "clausey-sdk";\nexport const sdkHelper = "clausey-helper";\nexport const sdkTool = "clausey-tool";\n`,
  );

  write(
    "entry.ts",
    [
      `import { dirname } from "node:path";`,
      `import "os";`,
      `import { twin } from "./rel-helper.js";`,
      `import { plainMain, tool } from "plain";`,
      `import { extra } from "plain2/extra.js";`,
      `import { cond } from "cond";`,
      `import { feature } from "wild/feat/one";`,
      `import { shade, feat, peer } from "chalklike";`,
      `import { label } from "jsony";`,
      `import { value } from "requirey";`,
      `import { hasCanvas } from "optional";`,
      `import { count } from "attrjson";`,
      `const dynamic = await import("cond");`,
      `export const summary = {`,
      `  twin, plainMain, tool, extra, cond, feature, shade, feat, peer, label, value, hasCanvas,`,
      `  attrjsonCount: count, dynamicCond: dynamic.cond, osTmpKind: typeof dirname,`,
      `};`,
    ].join("\n") + "\n",
  );
}

describe("PiModuleMirror", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-mirror-fixture-"));
  buildFixtureTree(root);
  const mirror = new PiModuleMirror(join(root, "mirror-out"));
  const outcome = mirror.mirrorEntry(join(root, "entry.ts"));

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
  });

  test("mirrors the entry into the mirror root, warning only on the optional native", () => {
    expect(outcome.url.startsWith("file://")).toBe(true);
    expect(outcome.url).toContain("mirror-out");
    expect(outcome.warnings).toHaveLength(1);
    expect(outcome.warnings[0]).toContain('unresolved import "canvas"');
  });

  test("the mirrored closure imports and preserves module semantics", async () => {
    const mod = await import(outcome.url);
    expect(mod.summary).toEqual({
      twin: "ts-twin",
      plainMain: "plain-main",
      tool: "plain-tool",
      extra: "plain2-extra",
      cond: "esm",
      feature: "wild-one",
      shade: "internal-shade",
      feat: "feat-one",
      peer: "scoped-peer",
      label: "jsony-label",
      value: "cjs-impl",
      hasCanvas: false,
      attrjsonCount: 7,
      dynamicCond: "esm",
      osTmpKind: "function",
    });
  });

  const cycOutcome = mirror.mirrorEntry(join(root, "node_modules/cyc/a.js"));

  test("import cycles terminate and evaluate", async () => {
    // Mirrored at collection time: bun test cannot import files written mid-test.
    expect(cycOutcome.warnings).toEqual([]);
    const mod = (await import(cycOutcome.url)) as { a: string };
    expect(mod.a).toBe("ab");
  });

  test("repeat mirroring is cached to the same file", () => {
    const again = new PiModuleMirror(join(root, "mirror-out"));
    const first = again.mirrorEntry(join(root, "entry.ts"));
    const second = again.mirrorEntry(join(root, "entry.ts"));
    expect(second.url).toBe(first.url);
  });

  const clauseyOutcome = mirror.mirrorEntry(join(root, "node_modules/clausey/index.js"));

  test("export clauses with parenthesized inline comments still resolve", async () => {
    // Regression for the 2026-10-13 pi:fetch_content outage: the clause class
    // must cross `(` `)` (comments) to reach `from` — pi-coding-agent 0.84.4
    // ships exactly this shape and the missed spec broke the flat mirror.
    expect(clauseyOutcome.warnings).toEqual([]);
    const mirroredEntry = readFileSync(new URL(clauseyOutcome.url).pathname, "utf8");
    expect(mirroredEntry).toContain('} from "file://');
    expect(mirroredEntry).not.toContain('"./core/sdk.js"');
    const mod = (await import(clauseyOutcome.url)) as { sdkValue: string; sdkHelper: string; sdkTool: string };
    expect(mod.sdkValue).toBe("clausey-sdk");
    expect(mod.sdkHelper).toBe("clausey-helper");
    expect(mod.sdkTool).toBe("clausey-tool");
  });
});

describe("scanAndLoadPiPackages mirror wiring", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-packages-fixture-"));

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
  });

  function writeDemoPackage(): string {
    const write = (relPath: string, content: string): void => {
      const target = join(root, relPath);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, content);
    };
    // Allowlist gates every load (empty/missing = deny): admit the fixture.
    write("pi-packages.json", JSON.stringify({ packages: ["demo"] }));
    write("pi-packages/package.json", JSON.stringify({ dependencies: { demo: "1.0.0" } }));
    write(
      "pi-packages/node_modules/demo/package.json",
      JSON.stringify({ name: "demo", pi: { extensions: ["./index.ts"] }, main: "./index.js" }),
    );
    write(
      "pi-packages/node_modules/demo/index.ts",
      `try { await import("missing-optional"); } catch {}\nexport default () => {};\n`,
    );
    return join(root, "pi-packages");
  }

  function demoSourceUrl(): string {
    return pathToFileURL(join(root, "pi-packages/node_modules/demo/index.ts")).href;
  }

  test("loads through the mirror by default and surfaces warnings in the summary", async () => {
    const loadedUrls: string[] = [];
    const summary = await scanAndLoadPiPackages(writeDemoPackage(), async (url) => {
      loadedUrls.push(url);
    });
    expect(loadedUrls).toHaveLength(1);
    expect(loadedUrls[0]).not.toBe(demoSourceUrl());
    expect(loadedUrls[0]).toContain("cetas-pi-mirror-");
    expect(summary.packages).toBe(1);
    expect(summary.entries).toBe(1);
    expect(summary.failures).toEqual([]);
    expect(summary.warnings).toHaveLength(1);
    expect(summary.warnings?.[0]).toContain('unresolved import "missing-optional"');
  });

  test("CETAS_PI_MIRROR=0 imports the original file URL", async () => {
    const previous = process.env.CETAS_PI_MIRROR;
    process.env.CETAS_PI_MIRROR = "0";
    try {
      const loadedUrls: string[] = [];
      const summary = await scanAndLoadPiPackages(writeDemoPackage(), async (url) => {
        loadedUrls.push(url);
      });
      expect(loadedUrls[0]).toBe(demoSourceUrl());
      expect(summary.warnings).toBeUndefined();
    } finally {
      if (previous === undefined) delete process.env.CETAS_PI_MIRROR;
      else process.env.CETAS_PI_MIRROR = previous;
    }
  });

  test("loaded set deduplicates by source URL across runs", async () => {
    const loaded = new Set<string>();
    let loads = 0;
    const load = async (): Promise<void> => {
      loads += 1;
    };
    await scanAndLoadPiPackages(writeDemoPackage(), load, loaded);
    await scanAndLoadPiPackages(writeDemoPackage(), load, loaded);
    expect(loads).toBe(1);
  });

  test("directory entries (pi-web-access >= 0.46.0) mirror dist/index.js without EISDIR", async () => {
    const write = (relPath: string, content: string): void => {
      const target = join(root, relPath);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, content);
    };
    write("pi-packages.json", JSON.stringify({ packages: ["dirdemo"] }));
    write("pi-packages/package.json", JSON.stringify({ dependencies: { dirdemo: "1.0.0" } }));
    write(
      "pi-packages/node_modules/dirdemo/package.json",
      JSON.stringify({ name: "dirdemo", pi: { extensions: ["./dist"] } }),
    );
    write("pi-packages/node_modules/dirdemo/dist/index.js", `export default () => "dist-index";\n`);
    const loadedUrls: string[] = [];
    const summary = await scanAndLoadPiPackages(join(root, "pi-packages"), async (url) => {
      loadedUrls.push(url);
    });
    expect(summary.packages).toBe(1);
    expect(summary.entries).toBe(1);
    expect(summary.failures).toEqual([]);
    // No EISDIR fallback: the mirror closure actually built, so no warnings.
    expect(summary.warnings).toBeUndefined();
    expect(loadedUrls).toHaveLength(1);
    expect(loadedUrls[0]).toContain("cetas-pi-mirror-");
    const mirrored = readFileSync(new URL(loadedUrls[0]).pathname, "utf8");
    expect(mirrored).toContain("dist-index");
  });
});

describe("resolvePiEntryFile", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-entry-resolve-"));

  const write = (relPath: string, content: string): void => {
    const target = join(root, relPath);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  };

  write("plain/index.js", `export const kind = "plain-index";\n`);
  write("idxmjs/dist/index.mjs", `export const kind = "index-mjs";\n`);
  write(
    "exportsbeat/package.json",
    JSON.stringify({ exports: { ".": "./esm.js" }, module: "./module.js", main: "./main.js" }),
  );
  write("exportsbeat/esm.js", `export const kind = "exports";\n`);
  write("exportsbeat/module.js", `export const kind = "module";\n`);
  write("exportsbeat/main.js", `export const kind = "main";\n`);
  write("exportsbeat/index.js", `export const kind = "index";\n`);
  write(
    "exportscond/package.json",
    JSON.stringify({
      exports: {
        ".": { types: "./types.d.ts", import: "./esm.mjs", default: "./default.js", node: "./node.js" },
      },
    }),
  );
  write("exportscond/types.d.ts", `export declare const kind: string;\n`);
  write("exportscond/esm.mjs", `export const kind = "import";\n`);
  write("exportscond/default.js", `export const kind = "default";\n`);
  write("exportscond/node.js", `export const kind = "node";\n`);
  write("modbeat/package.json", JSON.stringify({ module: "./module.js", main: "./main.js" }));
  write("modbeat/module.js", `export const kind = "module";\n`);
  write("modbeat/main.js", `export const kind = "main";\n`);
  write("mainbeat/package.json", JSON.stringify({ main: "./main.js" }));
  write("mainbeat/main.js", `export const kind = "main";\n`);
  write("mainextless/package.json", JSON.stringify({ main: "./lib/entry" }));
  write("mainextless/lib/entry.js", `export const kind = "main";\n`);
  mkdirSync(join(root, "emptydir"), { recursive: true });
  write("broken/package.json", JSON.stringify({ exports: "./missing.js" }));

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
  });

  test(`exports["."] (string) beats module, main, and index.js`, () => {
    expect(resolvePiEntryFile(join(root, "exportsbeat"))).toBe(join(root, "exportsbeat/esm.js"));
  });

  test(`exports["."] condition object picks import over default/node (types skipped)`, () => {
    expect(resolvePiEntryFile(join(root, "exportscond"))).toBe(join(root, "exportscond/esm.mjs"));
  });

  test("module beats main; main beats index.js", () => {
    expect(resolvePiEntryFile(join(root, "modbeat"))).toBe(join(root, "modbeat/module.js"));
    expect(resolvePiEntryFile(join(root, "mainbeat"))).toBe(join(root, "mainbeat/main.js"));
  });

  test("extensionless main resolves through candidate probing", () => {
    expect(resolvePiEntryFile(join(root, "mainextless"))).toBe(join(root, "mainextless/lib/entry.js"));
  });
});

describe("PiModuleMirror directory entries", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-mirror-dir-entry-"));

  const write = (relPath: string, content: string): void => {
    const target = join(root, relPath);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  };

  write("pkg/dist/index.js", `export default () => "dist-index";\n`);
  mkdirSync(join(root, "nothing"), { recursive: true });

  const mirror = new PiModuleMirror(join(root, "mirror-out"));

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
  });

  test("directory entry mirrors the resolved file with no EISDIR warning", () => {
    const outcome = mirror.mirrorEntry(join(root, "pkg/dist"));
    expect(outcome.warnings).toEqual([]);
    expect(outcome.url).toContain("mirror-out");
    const mirrored = readFileSync(new URL(outcome.url).pathname, "utf8");
    expect(mirrored).toContain("dist-index");
  });

  test("directory entry with no resolvable file warns and keeps the original URL", () => {
    const outcome = mirror.mirrorEntry(join(root, "nothing"));
    expect(outcome.url).toBe(pathToFileURL(join(root, "nothing")).href);
    expect(outcome.warnings).toHaveLength(1);
    expect(outcome.warnings[0]).toContain("resolved to no file");
    expect(outcome.warnings[0]).not.toContain("EISDIR");
  });
});
