// Test channel runner. `bun test` only takes substring filters, so channel
// membership is globbed here:
//   unit — pure TypeScript tests, no MoonBit preload (no moon build).
//   e2e  — `*.integration.test.ts` (real bridge) + smokes/ (subprocess boots).
// The full suite with preload stays `bun test` via package.json `test`.
import { Glob } from "bun";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = import.meta.dir;
const channel = process.argv[2];
if (channel !== "unit" && channel !== "e2e") {
  console.error("usage: bun test-channels.ts <unit|e2e>");
  process.exit(2);
}

const all = [
  ...new Glob("src/**/*.test.ts").scanSync({ cwd: root }),
  ...new Glob("ui/**/*.test.ts").scanSync({ cwd: root }),
  ...new Glob("smokes/*.test.ts").scanSync({ cwd: root }),
].sort();

const isE2E = (file: string) =>
  file.includes(".integration.test.ts") || file.startsWith("smokes/");
const files = all.filter((file) => (channel === "e2e" ? isE2E(file) : !isE2E(file)));
if (files.length === 0) {
  console.error(`no test files matched channel '${channel}'`);
  process.exit(2);
}

const args = ["test", ...(channel === "e2e" ? ["--preload", "./moonbit-preload.ts"] : []), ...files];
console.log(`[${channel}] ${files.length} test files`);
const proc = spawnSync(process.execPath, args, { cwd: root, stdio: "inherit" });
process.exit(proc.status ?? 1);
