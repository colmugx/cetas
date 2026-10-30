// Exercise the real pi-package scanner and mirror inside an AOT executable.
// The extension does not exist until AFTER compilation: it must be loaded
// from disk by the interpreter (allowCodeFromDisk), not bundled at build time.
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test.skipIf(process.env.CETAS_TEST_AOT !== "1")(
  "AOT binary loads an allowlisted external TypeScript pi extension with imports",
  async () => {
    const root = mkdtempSync(join(tmpdir(), "cetas-aot-pi-"));
    try {
      const source = join(root, "host.ts");
      const outfile = join(root, "host");
      writeFileSync(
        source,
        [
          `import { scanAndLoadPiPackages } from ${JSON.stringify(join(import.meta.dir, "../src/app/pi-packages.ts"))};`,
          `const root = process.env.CETAS_AOT_PI_ROOT;`,
          `if (!root) throw new Error("missing fixture root");`,
          `const result = await scanAndLoadPiPackages(joinRoot(root), async (url) => {`,
          `  const plugin = await import(url);`,
          `  if (plugin.default() !== "aot-pi-loaded") throw new Error("unexpected extension result");`,
          `});`,
          `if (result.entries !== 1 || result.failures.length !== 0) {`,
          `  throw new Error(JSON.stringify(result));`,
          `}`,
          `console.log("aot-pi-loaded");`,
          `function joinRoot(home: string): string { return home + "/pi-packages"; }`,
          "",
        ].join("\n"),
      );

      const compiled = await Bun.build({
        entrypoints: [source],
        target: "bun",
        compile: {
          outfile,
          aot: true,
          allowCodeFromDisk: true,
          autoloadBunfig: false,
        },
      });
      expect(
        compiled.success,
        compiled.logs.map((log) => String(log)).join("\n"),
      ).toBe(true);

      const packagesRoot = join(root, "pi-packages");
      const extensionRoot = join(packagesRoot, "fixture");
      mkdirSync(extensionRoot, { recursive: true });
      writeFileSync(join(root, "pi-packages.json"), JSON.stringify({ packages: ["fixture"] }));
      writeFileSync(
        join(extensionRoot, "package.json"),
        JSON.stringify({ name: "fixture", type: "module", pi: { extensions: ["./index.ts"] } }),
      );
      writeFileSync(
        join(extensionRoot, "index.ts"),
        'import { value } from "./helper.js";\nexport default () => value;\n',
      );
      writeFileSync(join(extensionRoot, "helper.ts"), 'export const value = "aot-pi-loaded";\n');

      const executable = process.platform === "win32" ? `${outfile}.exe` : outfile;
      const run = spawnSync(executable, [], {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, CETAS_AOT_PI_ROOT: root, CETAS_PI_MIRROR: "1" },
      });
      expect(run.status, `AOT pi extension failed:\n${run.stderr}`).toBe(0);
      expect(run.stdout).toContain("aot-pi-loaded");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
  300_000,
);
