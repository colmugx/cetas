// e2e: the shipped AOT compiled binary must not autoload bunfig preloads from
// the caller's cwd — build.ts compiles with autoloadBunfig: false, because
// a hostile bunfig.toml next to the invocation would otherwise execute
// before the CLI's own entry point. The preload here writes a marker file
// and throws: if the binary ever loads it, the run dies and the marker
// appears. Builds through the real `bun build.ts <target>` compile — the
// same path the release ships — for the current platform.
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const pkg = join(import.meta.dir, "..");

// The build.ts TARGETS keys reachable without cross-compiling (musl is
// glibc's sibling target on the same arch, detected via process.report).
const targetFor = (platform: string, arch: string): string | undefined => {
  if (platform === "darwin") return arch === "arm64" ? "darwin-arm64" : "darwin-x64";
  if (platform === "linux") {
    if (arch === "arm64") return "linux-arm64";
    if (arch === "x64") {
      const report = (process as unknown as { report?: { getReport?: () => { header?: { glibcVersionRuntime?: string } } } }).report?.getReport?.();
      return report?.header?.glibcVersionRuntime !== undefined ? "linux-x64" : "linux-x64-musl";
    }
  }
  if (platform === "win32" && arch === "x64") return "windows-x64";
  return undefined;
};

test(
  "compiled binary does not execute a hostile cwd bunfig preload",
  () => {
    const target = targetFor(process.platform, process.arch);
    expect(target, `unsupported platform ${process.platform}-${process.arch}`).toBeDefined();

    // Shipped build path; CETAS_PROTECT forced on like the node-bundle smoke
    // so the env matches the publishable build (protect() only rewrites the
    // node bundle — the binary's protection is autoloadBunfig: false).
    const build = spawnSync("bun", ["build.ts", target as string, "--aot"], {
      cwd: pkg,
      env: { ...process.env, CETAS_PROTECT: "1" },
    });
    expect(build.status, `build failed:\n${build.stderr.toString()}`).toBe(0);

    const exe = join(pkg, `dist/cetas-bun-${target}${target!.startsWith("windows") ? ".exe" : ""}`);
    expect(existsSync(exe), `missing compiled binary ${exe}`).toBe(true);

    const cwd = mkdtempSync(join(tmpdir(), "cetas-smoke-bunfig-"));
    try {
      writeFileSync(join(cwd, "bunfig.toml"), 'preload = ["./hostile-preload.ts"]\n');
      writeFileSync(
        join(cwd, "hostile-preload.ts"),
        [
          'import { writeFileSync } from "node:fs";',
          'writeFileSync(new URL("./hostile-ran.marker", import.meta.url), "ran\\n");',
          'throw new Error("CETAS-SMOKE-HOSTILE-PRELOAD-RAN");',
          "",
        ].join("\n"),
      );
      const run = spawnSync(exe, ["--version"], { cwd, encoding: "utf8" });
      expect(run.status, `binary failed in hostile cwd:\n${run.stderr}`).toBe(0);
      const version = readFileSync(join(pkg, "../VERSION"), "utf8").trim();
      expect(run.stdout).toContain(version);
      expect(run.stderr).not.toContain("CETAS-SMOKE-HOSTILE-PRELOAD-RAN");
      expect(existsSync(join(cwd, "hostile-ran.marker")), "hostile preload was executed").toBe(false);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  },
  // moon build + full Bun compile of a ~66 MB executable — generous timeout.
  900_000,
);
