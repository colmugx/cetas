// Pure compile script: knobs come from the environment, targets from argv,
// binaries land in dist/.
//
//   bun run build              # all targets
//   bun run build:macos        # single target (see package.json scripts)
//   bun build.ts darwin-arm64 windows-x64 linux-x64   # several targets, one run
//   CETAS_FLAVOR=personal bun run build:macos   # personal build: bake
//                                                # Nowledge Mem, Obsidian, RTK
//
//   bun build.ts darwin-arm64 --executable <path>   # supply a local Bun
//   binary for the target platform; skips Bun's runtime download (useful
//   when that download is slow or blocked — fetch e.g. bun-windows-x64.zip
//   from https://github.com/oven-sh/bun/releases). --executable needs
//   exactly one target.
//
// The MoonBit artifact is reached through the logical mbt: import, and the
// plugin owns the Moon build plus the .mbti/.d.ts refresh. The shell-ext platform bakes per target
// OS through cetas-core's platform_target knob (unix builds never register the
// ps1 ext, windows builds never register the bash ext); the preference-tied
// set (Nowledge Mem, Obsidian, RTK) bakes through the flavor_target knob from
// CETAS_FLAVOR (personal) or its absence (public). Each OS group is moon-built
// and immediately compiled, because the artifact on disk is always the last
// build. Both knobs restore to "auto" afterwards, so plain moon dev builds
// keep runtime detection.
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
const requested = new Set(positional.filter((a) => !a.startsWith("--")));

const osFor = (name: string) => (name.startsWith("windows") ? "windows" : "unix");
const PLATFORM_KNOB = join(import.meta.dir, "../cetas-core/lib/platform_target");
const PLATFORM_GEN = join(import.meta.dir, "../cetas-core/lib/platform_gen.sh");
const FLAVOR_KNOB = join(import.meta.dir, "../cetas-core/lib/flavor_target");
const FLAVOR_GEN = join(import.meta.dir, "../cetas-core/lib/flavor_gen.sh");
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
async function bakeKnobs(os: string, flavor: string) {
  await Bun.write(PLATFORM_KNOB, os + "\n");
  await Bun.write(FLAVOR_KNOB, flavor + "\n");
  for (const generator of [PLATFORM_GEN, FLAVOR_GEN]) {
    const result = Bun.spawnSync(["sh", generator], {
      cwd: import.meta.dir,
      stdout: "pipe",
      stderr: "pipe",
    });
    const stderr = result.stderr.toString().trim();
    if (result.exitCode !== 0) {
      throw new Error(
        `generator failed (${generator}): exitCode=${result.exitCode}` +
        (stderr.length > 0 ? `\nstderr:\n${stderr}` : ""),
      );
    }
    if (stderr.length > 0) {
      console.warn(`generator stderr (${generator}):\n${stderr}`);
    }
  }
}

let primaryFailure: unknown;
let hasPrimaryFailure = false;
try {
  console.log(`platform: per-target  flavor: ${flavorBake}${flavorBake === "personal" ? " (CETAS_FLAVOR=personal)" : ""}`);
  for (const os of [...new Set(selected.map(osFor))]) {
    await bakeKnobs(os, flavorBake);
    for (const name of selected.filter((n) => osFor(n) === os)) {
      const outfile = `dist/cetas-bun-${name}`;
      const result = await Bun.build({
        entrypoints: ["host.ts"],
        plugins: [
          moonbit({
            root: import.meta.dir,
            mode: "release",
            dts: {
              out: "gen/mbt.d.ts",
              externPolicy: {
                JsCallback: "(eventJson: string) => void",
                JsUiRenderCallback: "(eventJson: string) => void",
                JsUiRequestCallback: "(requestJson: string) => Promise<string>",
                JsCancelCheck: "() => boolean",
              },
            },
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
  }
} catch (error) {
  hasPrimaryFailure = true;
  primaryFailure = error;
  throw error;
} finally {
  // Leave the knobs and generated files at "auto" so the tree stays clean
  // and plain moon builds keep runtime detection for both dimensions.
  try {
    await bakeKnobs("auto", "auto");
  } catch (restoreError) {
    if (hasPrimaryFailure) {
      throw new AggregateError(
        [primaryFailure, restoreError],
        "Cetas build failed and restoring platform/flavor knobs also failed",
      );
    }
    throw restoreError;
  }
}
