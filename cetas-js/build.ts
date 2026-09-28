// Pure compile script: knobs come from the environment, targets from argv,
// binaries land in dist/.
//
//   bun run build              # all standalone targets
//   bun run build:macos        # single target (see package.json scripts)
//   bun build.ts darwin-arm64 windows-x64 linux-x64   # several targets, one run
//   bun run build:bundle       # minified single JS bundle; requires Bun at runtime
//   CETAS_FLAVOR=personal bun run build:macos   # personal build: bake
//                                                # Nowledge Mem, Obsidian, RTK
//
//   bun build.ts darwin-arm64 --executable <path>   # supply a local Bun
//   binary for the target platform; skips Bun's runtime download (useful
//   when that download is slow or blocked — fetch e.g. bun-windows-x64.zip
//   from https://github.com/oven-sh/bun/releases). --executable needs
//   exactly one target.
//
//   bun build.ts --dts-only   # regenerate gen/mbt.d.ts only (no binaries)
//
// cetas-core bakes the flavor table into a gitignored build_config.mbt from
// CETAS_FLAVOR (default public here) and CETAS_PLATFORM (per target OS);
// extensions the flavor does not hit are never constructed. The plugin's
// moon children re-fire that bake rule with the inherited environment, and
// Bun does not forward runtime process.env writes to children, so this
// script re-execs itself once per OS group with the group's env baked into
// the child's real environment.
import { rmSync } from "node:fs";
import { join } from "node:path";
import { moonbit } from "bun-plugin-moonbit";

const TARGETS = {
  "darwin-arm64": "bun-darwin-arm64",
  "darwin-x64": "bun-darwin-x64",
  // glibc, dynamically linked — Debian/Ubuntu/RHEL
  "linux-x64": "bun-linux-x64",
  // static musl — Alpine/distroless
  "linux-x64-musl": "bun-linux-x64-musl",
  "linux-arm64": "bun-linux-arm64",
  "windows-x64": "bun-windows-x64",
} as const;

const args = process.argv.slice(2);
const executableIdx = args.indexOf("--executable");
const executable = executableIdx >= 0 ? args[executableIdx + 1] : undefined;
const positional =
  executableIdx >= 0 ? [...args.slice(0, executableIdx), ...args.slice(executableIdx + 2)] : args;
const dtsOnly = positional.includes("--dts-only");
const bundleOnly = positional.includes("--bundle-only");
const requested = new Set(positional.filter((a) => !a.startsWith("--")));

if (dtsOnly && bundleOnly) {
  console.error("--dts-only and --bundle-only are mutually exclusive");
  process.exit(2);
}
if (bundleOnly && requested.size > 0) {
  console.error("--bundle-only builds for the current host OS and does not accept target names");
  process.exit(2);
}
if (bundleOnly && executable) {
  console.error("--executable only applies to standalone --compile builds");
  process.exit(2);
}

const osFor = (name: string) => (name.startsWith("windows") ? "windows" : "unix");
const hostOs = process.platform === "win32" ? "windows" : "unix";
const CORE_ROOT = join(import.meta.dir, "../cetas-core");
const BUILD_CONFIG = join(CORE_ROOT, "lib/build_config.mbt");
const GENERATOR = join(import.meta.dir, "../scripts/gen-build-config.sh");
const flavorBake = process.env.CETAS_FLAVOR === "personal" ? "personal" : "public";
const selected = (Object.keys(TARGETS) as (keyof typeof TARGETS)[]).filter(
  (name) => requested.size === 0 || requested.has(name),
);
const unknown = [...requested].filter((name) => !(name in TARGETS));
if (unknown.length > 0) {
  console.error(`unknown target: ${unknown.join(", ")}`);
  process.exit(2);
}
if (executable && selected.length !== 1) {
  console.error("--executable needs exactly one target: bun build.ts windows-x64 --executable <path>");
  process.exit(2);
}

const MOONBIT_DTS = {
  out: "gen/mbt.d.ts",
  externPolicy: {
    JsCallback: "(eventJson: string) => void",
    JsUiRenderCallback: "(eventJson: string) => void",
    JsUiRequestCallback: "(requestJson: string) => Promise<string>",
    JsCancelCheck: "() => boolean",
  },
};

const RELEASE_BUNDLE = {
  target: "bun" as const,
  minify: true,
  // Give dependencies a production-only branch to resolve against and make
  // process.env.NODE_ENV statically removable by Bun's dead-code elimination.
  conditions: ["production"],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
};

// The d.ts describes the API surface, not a flavor build: one pass, default
// env, no flavor bake, no re-exec, no binary output.
if (dtsOnly) {
  const result = await Bun.build({
    entrypoints: ["host.ts"],
    // bun target like the compile passes; browser (the default) rejects
    // pi-tui's node builtin imports.
    target: "bun",
    plugins: [moonbit({ root: import.meta.dir, mode: "release", dts: MOONBIT_DTS })],
  });
  if (!result.success) {
    console.error("✗ dts gen/mbt.d.ts");
    for (const log of result.logs) console.error(log);
    throw new Error("Bun.build failed for --dts-only");
  }
  console.log("✓ dts gen/mbt.d.ts");
  process.exit(0);
}

console.log(
  `platform: ${bundleOnly ? hostOs : "per-target"}  flavor: ${flavorBake}${
    flavorBake === "personal" ? " (CETAS_FLAVOR=personal)" : ""
  }`,
);

const group = process.env.CETAS_BUILD_GROUP ?? "";
if (group === "") {
  // Parent pass: standalone builds need one child per selected OS group.
  // Bundle-only has no cross-compile target, so it bakes for this host OS.
  const groups = bundleOnly ? [hostOs] : [...new Set(selected.map(osFor))];
  for (const os of groups) {
    const child = Bun.spawnSync(
      [process.execPath, import.meta.path, ...positional],
      {
        env: { ...process.env, CETAS_FLAVOR: flavorBake, CETAS_PLATFORM: os, CETAS_BUILD_GROUP: os },
        stdio: ["inherit", "inherit", "inherit"],
      },
    );
    if (child.exitCode !== 0) process.exit(child.exitCode ?? 1);
  }
  process.exit(0);
}

const os = group as ReturnType<typeof osFor>;

function prepareMoonbitForGroup(): void {
  // Bake this group's flavor before the plugin's moon build sees the tree:
  // drop the generated config, regenerate it from the cetas-core module root,
  // then moon-build once under the same env. The generated JS depends on the
  // OS group/flavor, not the CPU architecture, so one build can serve every
  // standalone target in this child.
  rmSync(BUILD_CONFIG, { force: true });
  const gen = Bun.spawnSync(["sh", GENERATOR], {
    cwd: CORE_ROOT,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (gen.exitCode !== 0) {
    console.error(`gen-build-config failed for ${os}:\n${gen.stderr.toString().trim()}`);
    process.exit(2);
  }
  const moonBuild = Bun.spawnSync(["moon", "build", "--target", "js", "--release"], {
    cwd: import.meta.dir,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (moonBuild.exitCode !== 0) {
    console.error(`moon build failed for ${os}:\n${moonBuild.stderr.toString().trim()}`);
    process.exit(2);
  }
}

prepareMoonbitForGroup();

if (bundleOnly) {
  if (os !== hostOs) {
    console.error(`bundle host/group mismatch: host=${hostOs}, group=${os}`);
    process.exit(2);
  }

  const outfile = "dist/cetas-bun-bundle.js";
  const result = await Bun.build({
    entrypoints: ["host.ts"],
    outfile,
    ...RELEASE_BUNDLE,
    plugins: [
      moonbit({
        root: import.meta.dir,
        mode: "release",
        dts: MOONBIT_DTS,
      }),
    ],
  });
  if (!result.success) {
    console.error("✗ bundle-only");
    for (const log of result.logs) console.error(log);
    throw new Error("Bun.build failed for --bundle-only");
  }
  const stat = await Bun.file(outfile).stat();
  console.log(`✓ bundle-only  ${(stat.size / 1024 / 1024).toFixed(2)} MB  (run with: bun ${outfile})`);
  process.exit(0);
}

for (const name of selected.filter((n) => osFor(n) === os)) {
  const outfile = `dist/cetas-bun-${name}`;
  const result = await Bun.build({
    entrypoints: ["host.ts"],
    ...RELEASE_BUNDLE,
    plugins: [
      moonbit({
        root: import.meta.dir,
        mode: "release",
        dts: MOONBIT_DTS,
      }),
    ],
    compile: {
      target: TARGETS[name],
      outfile,
      ...(executable ? { executablePath: executable } : {}),
    },
  });
  if (!result.success) {
    console.error(`✗ ${name}`);
    for (const log of result.logs) console.error(log);
    throw new Error(`Bun.build failed for ${name}`);
  }
  const ext = name.startsWith("windows") ? ".exe" : "";
  const stat = await Bun.file(outfile + ext).stat();
  console.log(`✓ ${name}  ${(stat.size / 1024 / 1024).toFixed(1)} MB`);
}
