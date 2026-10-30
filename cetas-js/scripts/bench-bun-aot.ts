// Compare the real cetas-js host in all Bun executable compilation modes.
// Run from cetas-js/ on a native Linux x64 CI runner after bun install + moon update.
import { appendFileSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { moonbit } from "bun-plugin-moonbit";

const root = join(import.meta.dir, "..");
const outputDir = join(root, "dist", "aot-benchmark");
mkdirSync(outputDir, { recursive: true });

if (process.platform !== "linux" || process.arch !== "x64") {
  throw new Error("AOT benchmark requires a native linux-x64 runner");
}

const version = readFileSync(join(root, "../VERSION"), "utf8").trim();
const built = Bun.spawnSync(["moon", "build", "--target", "js", "--release", "--output-json"], {
  cwd: root,
  env: process.env,
  stdout: "pipe",
  stderr: "pipe",
});
if (built.exitCode !== 0) {
  throw new Error(`MoonBit build failed:\n${built.stdout.toString()}\n${built.stderr.toString()}`);
}

const dts = {
  out: "gen/mbt.d.ts",
  externPolicy: {
    JsCallback: "(eventJson: string) => void",
    JsUiRenderCallback: "(eventJson: string) => void",
    JsUiRequestCallback: "(requestJson: string) => Promise<string>",
    JsCancelCheck: "() => boolean",
  },
};

const modes = [
  { name: "compile", options: {} },
  { name: "aot", options: { aot: true } },
  { name: "aot-disk", options: { aot: true, allowCodeFromDisk: true } },
  { name: "aot-disk-trim", options: { aot: true, allowCodeFromDisk: true, trim: true } },
] as const;

type ResultRow = {
  name: string;
  status: "ok" | "failed";
  bytes?: number;
  gzipBytes?: number;
  sha256?: string;
  versionOk?: boolean;
  diagnostic?: string;
};
const results: ResultRow[] = [];

for (const { name, options } of modes) {
  const outfile = join(outputDir, `cetas-bun-${name}`);
  rmSync(outfile, { force: true });
  try {
    const result = await Bun.build({
      entrypoints: [join(root, "host.ts")],
      target: "bun",
      plugins: [moonbit({ root, mode: "release", dts })],
      define: { __CETAS_VERSION__: JSON.stringify(version) },
      minify: true,
      compile: {
        target: "bun-linux-x64",
        outfile,
        autoloadBunfig: false,
        ...options,
      },
    });
    if (!result.success) {
      const diagnostic = result.logs.map(String).join("\n");
      console.error(`FAIL ${name}: ${diagnostic}`);
      results.push({ name, status: "failed", diagnostic });
      continue;
    }
    const executable = readFileSync(outfile);
    const bytes = executable.byteLength;
    const gzipBytes = gzipSync(executable, { level: 9 }).byteLength;
    const sha256 = createHash("sha256").update(executable).digest("hex");
    const run = Bun.spawnSync([outfile, "--version"], {
      cwd: root,
      stdout: "pipe",
      stderr: "pipe",
    });
    const versionOk =
      run.exitCode === 0 && run.stdout.toString().includes(`cetas-js ${version}`);
    const diagnostic = versionOk
      ? undefined
      : `--version exited ${run.exitCode}: ${run.stderr.toString()}`;
    results.push({
      name,
      status: versionOk ? "ok" : "failed",
      bytes,
      gzipBytes,
      sha256,
      versionOk,
      ...(diagnostic ? { diagnostic } : {}),
    });
    console.log(`${name}: ${bytes} bytes, gzip ${gzipBytes} bytes, sha256 ${sha256}; version ${versionOk ? "OK" : "FAILED"}`);
  } catch (error) {
    const diagnostic = error instanceof Error ? error.stack ?? error.message : String(error);
    console.error(`FAIL ${name}: ${diagnostic}`);
    results.push({ name, status: "failed", diagnostic });
  }
}


// The size table is not evidence that the flags took effect: verify distinct
// runtime semantics with an executable that checks built-in object mutability
// and imports a file created only after compilation.
const probeSource = join(outputDir, "aot-mode-probe.ts");
writeFileSync(probeSource, [
  'const descriptor = Object.getOwnPropertyDescriptor(Array.prototype, "push");',
  'console.log("builtin-writable:" + String(descriptor?.writable));',
  'try {',
  '  const module = await import(process.env.CETAS_PROBE_LATE_MODULE!);',
  '  console.log("late-import:" + module.default);',
  '} catch (e) {',
  '  console.log("late-import-denied:" + String((e as Error).code ?? (e as Error).message));',
  '}',
].join("\n") + "\n");

const probeResults: Array<{ name: string; success: boolean; stdout: string; stderr: string; logs?: string }> = [];
for (const { name, options } of modes) {
  const outfile = join(outputDir, `probe-${name}`);
  const result = await Bun.build({
    entrypoints: [probeSource],
    target: "bun",
    compile: {
      target: "bun-linux-x64",
      outfile,
      autoloadBunfig: false,
      ...options,
    },
  });
  const diagnostic = result.logs.map(String).join("\n");
  if (!result.success) {
    probeResults.push({ name, success: false, stdout: "", stderr: "", logs: diagnostic });
    console.error(`PROBE ${name}: compile failed: ${diagnostic}`);
    continue;
  }
  const lateModule = join(outputDir, `late-${name}.mjs`);
  writeFileSync(lateModule, 'export default "loaded";\n');
  const run = Bun.spawnSync([outfile], {
    cwd: outputDir,
    env: { ...process.env, CETAS_PROBE_LATE_MODULE: lateModule },
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = run.stdout.toString().trim();
  const stderr = run.stderr.toString().trim();
  probeResults.push({ name, success: run.exitCode === 0, stdout, stderr, ...(diagnostic ? { logs: diagnostic } : {}) });
  console.log(`PROBE ${name}: exit=${run.exitCode} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`);
}

const report = {
  bun: Bun.version,
  platform: process.platform,
  arch: process.arch,
  version,
  results,
  probeResults,
};
const reportFile = join(outputDir, "results.json");
writeFileSync(reportFile, JSON.stringify(report, null, 2) + "\n");

const fmt = (n: number | undefined): string =>
  n === undefined ? "-" : `${(n / 1048576).toFixed(2)} MiB`;
const baseline = results.find((row) => row.name === "compile")?.bytes;
const markdown = [
  `## cetas-js Bun binary size (Bun ${Bun.version}, linux-x64)`,
  "",
  "| Mode | Build and --version | Raw executable | gzip -9 | Delta to compile | SHA256 prefix |",
  "|---|---|---:|---:|---:|---|",
  ...results.map((row) =>
    `| ${row.name} | ${row.status} | ${fmt(row.bytes)} | ${fmt(row.gzipBytes)} | ${baseline !== undefined && row.bytes !== undefined ? `${((row.bytes - baseline) / 1048576).toFixed(2)} MiB` : "-"} | ${row.sha256?.slice(0, 16) ?? "-"} |`
  ),
  "",
  "### Runtime AOT/disk-code probes",
  "",
  "| Mode | Built-in Array.prototype.push writable? | Late external import |",
  "|---|---|---|",
  ...probeResults.map((row) => `| ${row.name} | ${row.stdout.match(/builtin-writable:(true|false)/)?.[1] ?? "unknown"} | ${row.stdout.match(/late-import:(loaded)/)?.[1] ?? (row.stdout.includes("late-import-denied:") ? "denied" : "unknown")} |`),
  "",
  "Includes the compiled cetas-js host only. Release pi-tui native sidecars are excluded.",
  "Any failed compilation or startup is recorded in the JSON artifact.",
  "",
].join("\n");
console.log(markdown);
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown + "\n");
}

// The two modes necessary for the PR must work. No-disk AOT and trim are
// experimental comparisons and can fail without masking the measurements.
if (results.some((row) =>
  (row.name === "compile" || row.name === "aot-disk") && row.status !== "ok"
)) {
  process.exitCode = 1;
}
