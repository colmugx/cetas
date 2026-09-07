// Compiled Bun binaries (`bun build --compile`) perform no node_modules
// resolution for externally dynamic-imported files, so a pi package cannot
// resolve its own dependency graph at runtime. This loader mirrors an entry's
// statically discoverable import closure into one flat per-boot directory,
// rewriting every non-builtin specifier to an absolute file URL (require()
// gets an absolute path). Unresolvable specifiers stay untouched and are
// reported as warnings: load failures and validation authority are unchanged.

import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { builtinModules } from "node:module";
import { tmpdir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const BUILTIN_NAMES = new Set(builtinModules);

const TS_EXTENSIONS = [".ts", ".tsx", ".mts", ".cts"] as const;
const JS_EXTENSIONS = [".js", ".jsx", ".mjs", ".cjs"] as const;

interface ScannedImport {
  kind: string;
  path: string;
}

export interface MirrorOutcome {
  /** file:// URL of the mirrored entry (the original when mirroring failed). */
  url: string;
  /** Non-fatal diagnostics: unresolved imports, unreadable files. */
  warnings: readonly string[];
}

/**
 * One mirror session: a flat directory holding the mirrored closure of every
 * entry processed through it. Per process, hosts reuse `sharedPiModuleMirror`
 * so repeated loads (agent recomposition) hit the same cache.
 */
export class PiModuleMirror {
  readonly root: string;

  private readonly mirrored = new Map<string, string>();
  private readonly manifests = new Map<string, Record<string, unknown> | undefined>();

  constructor(root: string) {
    this.root = root;
    try {
      mkdirSync(root, { recursive: true });
      // The real packages are `"type": "module"`; pinned here so mirrored .js
      // never falls back to CJS interpretation. Genuinely CJS files keep their
      // .cjs extension (see mirrorExtensionFor).
      writeFileSync(join(root, "package.json"), '{"type":"module"}\n');
    } catch {
      // Without a writable root nothing mirrors; callers fall back to the
      // original entry URL and see per-file warnings.
    }
  }

  mirrorEntry(entryAbsPath: string): MirrorOutcome {
    const warnings: string[] = [];
    let sourcePath: string;
    try {
      sourcePath = realpathSync(entryAbsPath);
    } catch (error) {
      warnings.push(`entry unreadable: ${entryAbsPath}: ${describeError(error)}`);
      return { url: pathToFileURL(entryAbsPath).href, warnings };
    }
    const mirroredPath = this.mirrorFile(sourcePath, warnings);
    return { url: pathToFileURL(mirroredPath ?? sourcePath).href, warnings };
  }

  private mirrorFile(sourcePath: string, warnings: string[], jsonAttribute = false): string | undefined {
    const mapKey = jsonAttribute ? `json:${sourcePath}` : sourcePath;
    const existing = this.mirrored.get(mapKey);
    if (existing !== undefined) return existing;

    let source: string;
    try {
      source = readFileSync(sourcePath, "utf8");
    } catch (error) {
      warnings.push(`unreadable: ${sourcePath}: ${describeError(error)}`);
      return undefined;
    }

    const isJson = sourcePath.endsWith(".json");
    // `import x from "...json" with { type: "json" }` makes the loader parse
    // the module itself as JSON, so those targets are mirrored raw instead of
    // wrapped in `export default`.
    const rawJson = jsonAttribute && isJson;
    const content = isJson && !rawJson ? `export default ${source.trim()};` : source;
    const outPath = this.mirrorPathFor(sourcePath, content, isJson, rawJson);
    // Pre-register before recursion: import cycles resolve to a stable path.
    this.mirrored.set(mapKey, outPath);

    let rewritten = content;
    if (!isJson) {
      for (const scanned of this.scannedImports(content, sourcePath, warnings)) {
        const spec = scanned.path;
        if (skipRewrite(spec)) continue;
        let target: string | undefined;
        try {
          target = spec.startsWith("#")
            ? this.resolveSubpathImport(spec, dirname(sourcePath))
            : spec.startsWith(".") || spec.startsWith("/")
              ? this.resolveRelative(spec, dirname(sourcePath))
              : this.resolveBare(spec, dirname(sourcePath));
        } catch (error) {
          warnings.push(`resolution failed for "${spec}" in ${sourcePath}: ${describeError(error)}`);
        }
        if (target === undefined) {
          warnings.push(`unresolved import "${spec}" in ${sourcePath}; left as-is`);
          continue;
        }
        const mirroredTarget = this.mirrorFile(target, warnings, hasJsonImportAttribute(content, spec));
        if (mirroredTarget === undefined) continue;
        // require() accepts absolute paths only; both import() and require()
        // accept file:// URLs (Bun).
        const replacement = scanned.kind === "require-call"
          ? mirroredTarget
          : pathToFileURL(mirroredTarget).href;
        for (const quote of ['"', "'", "`"]) {
          rewritten = rewritten
            .split(`${quote}${spec}${quote}`)
            .join(`${quote}${replacement}${quote}`);
        }
      }
    }

    try {
      writeFileSync(outPath, rewritten);
    } catch (error) {
      this.mirrored.delete(mapKey);
      warnings.push(`mirror write failed: ${sourcePath}: ${describeError(error)}`);
      return undefined;
    }
    return outPath;
  }

  private scannedImports(content: string, sourcePath: string, warnings: string[]): ScannedImport[] {
    const extension = extname(sourcePath);
    const loader = extension === ".tsx" || extension === ".jsx"
      ? "tsx"
      : TS_EXTENSIONS.includes(extension as (typeof TS_EXTENSIONS)[number])
        ? "ts"
        : "js";
    try {
      return new Bun.Transpiler({ loader }).scanImports(content) as ScannedImport[];
    } catch (error) {
      warnings.push(`import scan failed: ${sourcePath}: ${describeError(error)}`);
      return [];
    }
  }

  private mirrorPathFor(sourcePath: string, content: string, isJson: boolean, rawJson: boolean): string {
    const extension = rawJson ? ".json" : isJson ? ".ts" : mirrorExtensionFor(sourcePath, content);
    const stem = basename(sourcePath).replace(/\.[^.]*$/, "").replace(/[^A-Za-z0-9._-]/g, "_");
    const hash = createHash("sha256").update(sourcePath).digest("hex").slice(0, 8);
    return join(this.root, `${stem}-${hash}${extension}`);
  }

  private resolveRelative(spec: string, fromDir: string): string | undefined {
    return firstFile(fileCandidates(resolve(fromDir, spec)));
  }

  /** Node "imports" (`#spec`): nearest package.json declaring it, walking up. */
  private resolveSubpathImport(spec: string, fromDir: string): string | undefined {
    let dir = fromDir;
    for (;;) {
      const manifest = this.manifestOf(join(dir, "package.json"));
      const relative = manifest === undefined ? undefined : resolveImportsMap(manifest.imports, spec);
      if (relative !== undefined) {
        const candidate = resolve(dir, relative);
        if (isFile(candidate)) return candidate;
      }
      const parent = dirname(dir);
      if (parent === dir) return undefined;
      dir = parent;
    }
  }

  private resolveBare(spec: string, fromDir: string): string | undefined {
    const segments = spec.split("/");
    const scoped = spec.startsWith("@");
    const pkgName = scoped ? segments.slice(0, 2).join("/") : segments[0];
    const sub = segments.slice(scoped ? 2 : 1).join("/");
    let dir = fromDir;
    for (;;) {
      const hit = this.resolveFromPackageRoot(join(dir, "node_modules", pkgName), sub);
      if (hit !== undefined) return hit;
      const parent = dirname(dir);
      if (parent === dir) return undefined;
      dir = parent;
    }
  }

  private resolveFromPackageRoot(pkgRoot: string, sub: string): string | undefined {
    if (!isFile(join(pkgRoot, "package.json")) && !isDir(pkgRoot)) return undefined;
    const manifest = this.manifestOf(join(pkgRoot, "package.json"));
    if (manifest?.exports !== undefined) {
      const relative = resolveExportsMap(manifest.exports, sub);
      if (relative !== undefined) {
        const target = resolve(pkgRoot, relative);
        if (isFile(target)) return target;
      }
    }
    if (sub !== "") return firstFile(fileCandidates(resolve(pkgRoot, sub)));
    const main = typeof manifest?.module === "string"
      ? manifest.module
      : typeof manifest?.main === "string"
        ? manifest.main
        : undefined;
    if (main !== undefined) {
      const hit = firstFile(fileCandidates(resolve(pkgRoot, main)));
      if (hit !== undefined) return hit;
    }
    return firstFile(fileCandidates(join(pkgRoot, "index")));
  }

  private manifestOf(path: string): Record<string, unknown> | undefined {
    const cached = this.manifests.get(path);
    if (cached !== undefined || this.manifests.has(path)) return cached;
    let manifest: Record<string, unknown> | undefined;
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
      if (isRecord(parsed)) manifest = parsed;
    } catch {
      manifest = undefined;
    }
    this.manifests.set(path, manifest);
    return manifest;
  }
}

let sharedMirror: PiModuleMirror | undefined;

/** Per-process mirror session backed by one mkdtemp root. */
export function sharedPiModuleMirror(): PiModuleMirror {
  if (sharedMirror === undefined) {
    sharedMirror = new PiModuleMirror(mkdtempSync(join(tmpdir(), "cetas-pi-mirror-")));
  }
  return sharedMirror;
}

/** Mirror one entry through the shared per-process session. */
export function mirrorPiEntry(entryAbsPath: string): MirrorOutcome {
  return sharedPiModuleMirror().mirrorEntry(entryAbsPath);
}

function skipRewrite(spec: string): boolean {
  if (spec.startsWith("node:") || spec.startsWith("bun:")) return true;
  if (spec.startsWith("file:") || spec.startsWith("data:") || spec.startsWith("http")) return true;
  if (BUILTIN_NAMES.has(spec)) return true;
  const slash = spec.indexOf("/");
  return slash > 0 && BUILTIN_NAMES.has(spec.slice(0, slash));
}

/** Whether the spec is imported with `with/assert { type: "json" }` in this file. */
function hasJsonImportAttribute(content: string, spec: string): boolean {
  const escaped = spec.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `['"\`]${escaped}['"\`]\\s*(?:with|assert)\\s*\\{[^}]*type\\s*:\\s*['"]json['"]`,
  ).test(content);
}

function mirrorExtensionFor(sourcePath: string, content: string): string {
  const extension = extname(sourcePath);
  if (extension === ".mjs" || extension === ".cjs") return extension;
  if (TS_EXTENSIONS.includes(extension as (typeof TS_EXTENSIONS)[number])) return extension;
  // Under the mirror's `"type": "module"` root, genuinely CJS .js files keep
  // CJS semantics only through the .cjs extension.
  if (extension === ".js" && looksLikeCommonJs(content)) return ".cjs";
  return ".js";
}

function looksLikeCommonJs(content: string): boolean {
  if (/^\s*(?:import|export)[\s{*'"]/.test(content)) return false;
  return /\bmodule\s*\.\s*exports\b|\bexports\s*\.\s*[A-Za-z_$]/.test(content);
}

/**
 * Probe order for one path stem: exact file, TS twins of a JS-style suffix
 * (`./x.js` importing `x.ts`), appended extensions, directory index.
 */
function fileCandidates(base: string): string[] {
  const candidates = [base];
  const extension = extname(base);
  if (JS_EXTENSIONS.includes(extension as (typeof JS_EXTENSIONS)[number])) {
    const stem = base.slice(0, base.length - extension.length);
    candidates.push(...TS_EXTENSIONS.map((ts) => stem + ts));
  }
  candidates.push(...TS_EXTENSIONS.map((ext) => base + ext));
  candidates.push(...JS_EXTENSIONS.map((ext) => base + ext));
  candidates.push(`${base}.json`, ...TS_EXTENSIONS.map((ext) => join(base, `index${ext}`)),
    ...JS_EXTENSIONS.map((ext) => join(base, `index${ext}`)), join(base, "index.json"));
  return candidates;
}

function firstFile(candidates: readonly string[]): string | undefined {
  for (const candidate of candidates) {
    if (isFile(candidate)) return candidate;
  }
  return undefined;
}

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function isDir(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Resolve one key (`"."` or `"./sub"`) against a package.json `exports`. */
function resolveExportsMap(exportsField: unknown, sub: string): string | undefined {
  const key = sub === "" ? "." : `./${sub}`;
  if (typeof exportsField === "string") return sub === "" ? exportsField : undefined;
  if (!isRecord(exportsField)) return undefined;
  const exact = exportsField[key];
  if (exact !== undefined) return pickConditions(exact);
  for (const [pattern, value] of Object.entries(exportsField)) {
    const star = pattern.indexOf("*");
    if (star < 0) continue;
    const prefix = pattern.slice(0, star);
    const suffix = pattern.slice(star + 1);
    if (!key.startsWith(prefix) || !key.endsWith(suffix)) continue;
    const infix = key.slice(prefix.length, key.length - suffix.length);
    const hit = pickConditions(substituteStar(value, infix));
    if (hit !== undefined) return hit;
  }
  return undefined;
}

/** Resolve one `#spec` against a package.json `imports` map. */
function resolveImportsMap(importsField: unknown, spec: string): string | undefined {
  if (!isRecord(importsField)) return undefined;
  const exact = importsField[spec];
  if (exact !== undefined) {
    const hit = pickConditions(exact);
    if (hit !== undefined) return hit;
  }
  for (const [pattern, value] of Object.entries(importsField)) {
    const star = pattern.indexOf("*");
    if (star < 0) continue;
    const prefix = pattern.slice(0, star);
    const suffix = pattern.slice(star + 1);
    if (!spec.startsWith(prefix) || !spec.endsWith(suffix)) continue;
    const infix = spec.slice(prefix.length, spec.length - suffix.length);
    const hit = pickConditions(substituteStar(value, infix));
    if (hit !== undefined) return hit;
  }
  return undefined;
}

/**
 * Condition objects are walked depth-first in declaration order, skipping
 * `types` (declaration files), `require` (an import context wants ESM), and
 * `browser` (the host is a Bun/Node runtime).
 */
function pickConditions(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    for (const item of value) {
      const hit = pickConditions(item);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }
  if (isRecord(value)) {
    for (const [key, item] of Object.entries(value)) {
      if (key === "types" || key === "typings" || key === "require" || key === "browser") continue;
      const hit = pickConditions(item);
      if (hit !== undefined) return hit;
    }
  }
  return undefined;
}

function substituteStar(value: unknown, replacement: string): unknown {
  if (typeof value === "string") return value.replace("*", replacement);
  if (Array.isArray(value)) return value.map((item) => substituteStar(item, replacement));
  if (isRecord(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, substituteStar(item, replacement)]),
    );
  }
  return value;
}
