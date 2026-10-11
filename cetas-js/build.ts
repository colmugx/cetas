// Pure compile script: knobs come from the environment, targets from argv,
// binaries land in dist/.
//
//   bun run build              # all targets
//   bun run build:macos        # single target (see package.json scripts)
//   bun build.ts darwin-arm64 windows-x64 linux-x64   # several targets, one run
//   bun build.ts darwin-arm64 --executable <path>   # supply a local Bun
//   binary for the target platform; skips Bun's runtime download (useful
//   when that download is slow or blocked — fetch e.g. bun-windows-x64.zip
//   from https://github.com/oven-sh/bun/releases). --executable needs
//   exactly one target.
//
//   bun build.ts --dts-only   # regenerate gen/mbt.d.ts only (no binaries)
//
// Public composition is checked in as MoonBit source; building does not
// mutate the package graph or generate recipe sources.
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
const nodeBundle = positional.includes("--node-bundle");
const requested = new Set(positional.filter((a) => !a.startsWith("--")));

const osFor = (name: string) => (name.startsWith("windows") ? "windows" : "unix");
const CORE_ROOT = join(import.meta.dir, "../cetas-core");
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

// Generate d.ts from the checked-in MoonBit composition.
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

console.log("platform: per-target  composition: checked-in MoonBit sources");

// npm channel: one platform-independent JS bundle. The bash/ps1 swap detects
// the platform at runtime (checked-in MoonBit), node:child_process/node:http
// run under both bun and node, and pi-tui stays external so its native
// .node addons resolve from node_modules. No sourcemap is generated
// (Bun.build defaults to "none").
if (nodeBundle) {
  const moonBuild = Bun.spawnSync(["moon", "build", "--target", "js", "--release"], {
    cwd: import.meta.dir,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (moonBuild.exitCode !== 0) {
    console.error(`moon build failed for the node bundle:\n${moonBuild.stderr.toString().trim()}`);
    process.exit(2);
  }
  const result = await Bun.build({
    entrypoints: ["host.ts"],
    target: "node",
    minify: true,
    external: ["@earendil-works/pi-tui"],
    plugins: [
      moonbit({
        root: import.meta.dir,
        mode: "release",
        dts: MOONBIT_DTS,
      }),
    ],
  });
  if (!result.success) {
    console.error("✗ node bundle");
    for (const log of result.logs) console.error(log);
    throw new Error("Bun.build failed for --node-bundle");
  }
  // Bun.build's JS API silently ignores a top-level outfile — write the
  // single output blob by hand, shebang first so npm bin shims exec node.
  const [out] = result.outputs;
  await Bun.write("dist/cetas.js", `#!/usr/bin/env node\n${await out.text()}`);
  const stat = await Bun.file("dist/cetas.js").stat();
  console.log(`✓ node bundle  dist/cetas.js  ${(stat.size / 1024 / 1024).toFixed(1)} MB`);
  process.exit(0);
}

const group = process.env.CETAS_BUILD_GROUP ?? "";
if (group === "") {
  // Parent pass: one child per OS group, preserving target platform settings.
  for (const os of [...new Set(selected.map(osFor))]) {
    const child = Bun.spawnSync(
      [process.execPath, import.meta.path, ...positional],
      {
        env: { ...process.env, CETAS_PLATFORM: os, CETAS_BUILD_GROUP: os },
        stdio: ["inherit", "inherit", "inherit"],
      },
    );
    if (child.exitCode !== 0) process.exit(child.exitCode ?? 1);
  }
  process.exit(0);
}

const os = group as ReturnType<typeof osFor>;
for (const name of selected.filter((n) => osFor(n) === os)) {
  // Build from the checked-in MoonBit composition.
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
  const outfile = `dist/cetas-bun-${name}`;
  const result = await Bun.build({
    entrypoints: ["host.ts"],
    plugins: [
      moonbit({
        root: import.meta.dir,
        mode: "release",
        dts: MOONBIT_DTS,
      }),
    ],
    compile: { target: TARGETS[name], outfile, ...(executable ? { executablePath: executable } : {}) },
    minify: true,
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
