// e2e: the npm node bundle must build with protection enabled and boot far
// enough to answer --version under plain node. CETAS_PROTECT is forced on:
// the publishable artifact is the protected one.
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const pkg = join(import.meta.dir, "..");

test(
  "node bundle builds protected and answers --version",
  () => {
    const build = spawnSync("bun", ["build.ts", "--node-bundle"], {
      cwd: pkg,
      env: { ...process.env, CETAS_PROTECT: "1" },
    });
    expect(build.status, `build failed:\n${build.stderr.toString()}`).toBe(0);

    const run = spawnSync("node", [join(pkg, "dist/cetas.js"), "--version"], { encoding: "utf8" });
    expect(run.status, run.stderr).toBe(0);
    const version = readFileSync(join(pkg, "../VERSION"), "utf8").trim();
    expect(run.stdout).toContain(version);

    // Protection took effect: a string that exists in source must not
    // survive in the artifact plaintext.
    const bundle = readFileSync(join(pkg, "dist/cetas.js"), "utf8");
    expect(bundle).not.toContain("cetas-js-crash.log");
  },
  300_000,
);
