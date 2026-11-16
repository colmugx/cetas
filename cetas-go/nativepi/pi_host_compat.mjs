// Cetas's Pi host module adapter. Pi extensions run inside Bun, but there is
// no second Pi Agent. Only the explicitly bridged host surface is exported.
// Keep real third-party utilities (e.g. typebox) in the npm package graph.
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
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

function hostModuleRoot(specifier) {
  for (const name of Object.keys(hostModules)) {
    if (specifier === name || specifier.startsWith(name + "/")) return name;
  }
  return undefined;
}

function rewriteHostImports(source, shims) {
  // Bun 1.4.x runtime plugins do not run onResolve for bare package names.
  // onLoad does run for file-backed modules, so rewrite only Pi-owned imports
  // in the source before Bun's normal resolver sees them. Third-party imports
  // remain untouched and continue through Bun's package resolver.
  const patterns = [
    {
      kind: "import",
      regex: /((?:^|[;{}\s])(?:import|export)\s+(?:[^;'"]*?\bfrom\s*)?)(["'\x60])([^"'\x60\n]+)\2/g,
    },
    {
      kind: "dynamic-import",
      regex: /(\bimport\s*\(\s*)(["'\x60])([^"'\x60\n]+)\2/g,
    },
    {
      kind: "require",
      regex: /(\brequire\s*\(\s*)(["'\x60])([^"'\x60\n]+)\2/g,
    },
  ];
  let rewritten = source;
  for (const pattern of patterns) {
    pattern.regex.lastIndex = 0;
    rewritten = rewritten.replace(pattern.regex, (match, prefix, quote, specifier) => {
      const root = hostModuleRoot(specifier);
      if (root === undefined) return match;
      const shim = shims[root];
      const target = pattern.kind === "require" ? shim.path : shim.url;
      return prefix + quote + target + quote;
    });
  }
  return rewritten;
}

function isWithin(root, path) {
  const rel = relative(root, path);
  return rel === "" || (rel !== ".." && !rel.startsWith(".." + sep) && !isAbsolute(rel));
}

function loaderFor(path) {
  switch (extname(path).toLowerCase()) {
    case ".ts":
    case ".mts":
    case ".cts":
      return "ts";
    case ".tsx":
      return "tsx";
    case ".jsx":
      return "jsx";
    default:
      return "js";
  }
}

// Install a file-load transform instead of a bare-specifier resolver. This is
// deliberately scoped to the allowlisted package tree: it cannot rewrite host
// code or unrelated application dependencies. The returned disposer removes
// the per-guest shim files when the isolated Bun process shuts down.
export function installPiHostCompat(packageRoot) {
  let canonicalRoot = resolve(packageRoot);
  try {
    canonicalRoot = realpathSync(canonicalRoot);
  } catch {}

  const shimRoot = mkdtempSync(join(tmpdir(), "cetas-pi-host-"));
  const shims = Object.create(null);
  for (const [name, contents] of Object.entries(hostModules)) {
    const shortName = name.slice(name.lastIndexOf("/") + 1);
    const path = join(shimRoot, shortName + ".mjs");
    writeFileSync(path, contents, { mode: 0o600 });
    shims[name] = { path, url: pathToFileURL(path).href };
  }

  // Bun 1.4.4 requires every matching onLoad callback to return a module
  // object. Scope the filter to the allowlisted root, so foreign dependencies
  // and generated host shims remain on Bun\'s ordinary module loader.
  const escapedRoot = canonicalRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const loadFilter = new RegExp("^" + escapedRoot + "[/\\\\].*\\.(?:[cm]?[jt]sx?)$");
  Bun.plugin({
    name: "cetas-pi-host",
    setup(build) {
      build.onLoad({ filter: loadFilter }, args => {
        let sourcePath = resolve(args.path);
        try {
          sourcePath = realpathSync(sourcePath);
        } catch {}
        if (!isWithin(canonicalRoot, sourcePath)) {
          throw new Error("Pi module escapes the allowlisted package tree: " + sourcePath);
        }
        const source = readFileSync(sourcePath, "utf8");
        const contents = source.includes("@earendil-works/pi-")
          ? rewriteHostImports(source, shims)
          : source;
        return {
          contents,
          loader: loaderFor(sourcePath),
          resolveDir: dirname(sourcePath),
        };
      });
    },
  });

  return () => rmSync(shimRoot, { recursive: true, force: true });
}
