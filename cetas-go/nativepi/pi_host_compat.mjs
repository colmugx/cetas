// Cetas's Pi host module adapter.
//
// Do not depend on Bun runtime plugin hooks to resolve host-owned bare
// specifiers. Bun's runtime plugin path handling differs on Windows, and the
// import fails before an onLoad transform can reliably rewrite it.
//
// Pi extensions are loaded from <CETAS_HOME>/.cetas/pi-packages/node_modules.
// Install small, scoped host packages into that same node_modules tree so
// Bun's normal Node-compatible package resolver finds them on every OS.
// Third-party dependencies remain untouched and use the normal package graph.
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const hostModules = {
  "@earendil-works/pi-tui": [
    'export function truncateToWidth(input, width, suffix = "…") {',
    '  if (!Number.isFinite(width) || width <= 0) return "";',
    '  const text = String(input ?? "");',
    '  if (Bun.stringWidth(text) <= width) return text;',
    '  const tail = Bun.stringWidth(suffix) < width ? suffix : "";',
    '  let result = "";',
    '  for (const codepoint of text) {',
    '    if (Bun.stringWidth(result + codepoint + tail) > width) break;',
    '    result += codepoint;',
    '  }',
    '  return result + tail;',
    '}',
    '// A headless Pi guest cannot create a terminal-controlled component.',
    '// Exports satisfy static imports, but actual UI use must be explicit.',
    'function unavailable() {',
    '  throw new Error("Pi terminal components require a native UI adapter; Bun guest is headless");',
    '}',
    'export class Box { constructor() { unavailable(); } }',
    'export class Text { constructor() { unavailable(); } }',
  ].join("\n"),
  "@earendil-works/pi-agent-core": [
    '// Agent-core is a host-owned namespace, not a second runtime.',
    'export const host = "cetas";',
  ].join("\n"),
  "@earendil-works/pi-ai": [
    '// Runtime imports are intentionally limited; type-only Pi AI imports',
    '// disappear during compilation. Unknown runtime APIs fail explicitly.',
    'export const host = "cetas";',
  ].join("\n"),
  "@earendil-works/pi-coding-agent": [
    'import { join } from "node:path";',
    'export function getAgentDir() {',
    '  const home = process.env.CETAS_HOME || process.env.HOME || process.env.USERPROFILE;',
    '  if (!home) throw new Error("Cetas home is unavailable to the Pi guest");',
    '  return join(home, ".cetas");',
    '}',
    'export function buildSessionContext(branch) {',
    '  if (!Array.isArray(branch)) throw new Error("Pi session branch was not supplied by the Cetas host");',
    '  return { messages: branch.filter(entry => entry?.type === "message" && entry.message && typeof entry.message === "object").map(entry => entry.message) };',
    '}',
    'export async function resizeImage() {',
    '  throw new Error("Pi resizeImage is not exposed by the Cetas native Pi host");',
    '}',
  ].join("\n"),
};

export function installPiHostCompat(packageRoot) {
  const scopeRoot = join(packageRoot, "node_modules", "@earendil-works");
  mkdirSync(scopeRoot, { recursive: true });

  const created = [];
  for (const [name, contents] of Object.entries(hostModules)) {
    const packageName = name.slice(name.lastIndexOf("/") + 1);
    const packageDir = join(scopeRoot, packageName);

    // Never overwrite a package supplied by the user or package manager.
    // If it already exists, Bun's normal resolver will load that package.
    if (existsSync(packageDir)) continue;

    mkdirSync(packageDir, { recursive: true });
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name,
        version: "0.0.0-cetas-host",
        type: "module",
        main: "./index.mjs",
        module: "./index.mjs",
        exports: {
          ".": "./index.mjs",
          "./*": "./index.mjs",
        },
      }, null, 2),
      { mode: 0o600 },
    );
    writeFileSync(join(packageDir, "index.mjs"), contents + "\n", { mode: 0o600 });
    created.push(packageDir);
  }

  // Only remove packages created by this guest. The user's package tree and
  // any pre-existing @earendil-works packages are never deleted.
  return () => {
    for (const packageDir of created) {
      rmSync(packageDir, { recursive: true, force: true });
    }
  };
}
