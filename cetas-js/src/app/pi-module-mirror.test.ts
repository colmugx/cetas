import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, describe, expect, test } from "bun:test";

import { PiModuleMirror } from "./pi-module-mirror.ts";
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

  test("json imported with type attributes stays raw json", () => {
    const dir = new URL("./", outcome.url).pathname;
    const rawJson = readdirSync(dir).find((name) => name.startsWith("data-") && name.endsWith(".json"));
    expect(rawJson).toBeDefined();
    expect(readFileSync(join(dir, rawJson as string), "utf8")).not.toContain("export default");
  });

  test("builtins stay untouched; resolved bare specs become absolute URLs", () => {
    const mirroredEntry = readFileSync(new URL(outcome.url).pathname, "utf8");
    expect(mirroredEntry).toContain('"node:path"');
    expect(mirroredEntry).toContain('"os"');
    expect(mirroredEntry).toContain('from "file://');
    expect(mirroredEntry).not.toContain('from "plain"');
    expect(mirroredEntry).not.toContain('from "jsony"');
  });

  test("json dependencies are wrapped as export default", () => {
    const dir = new URL("./", outcome.url).pathname;
    const jsonMirror = readdirSync(dir).find(
      (name) => name.startsWith("config-") && name.endsWith(".ts"),
    );
    expect(jsonMirror).toBeDefined();
    expect(readFileSync(join(dir, jsonMirror as string), "utf8")).toMatch(/^export default \{/);
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
});
