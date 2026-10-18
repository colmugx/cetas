// Post-build protection for the npm node bundle (deterrent-grade: the key
// ships with the artifact, this raises the reverse-engineering bar only).
//
//   A. javascript-obfuscator — conservative profile that keeps CLI startup
//      fast; CETAS_OBFUSCATION=max opts into the heavy transforms.
//   B. acorn/estree-walker/astring — every static string literal is replaced
//      with an indexed lookup into one AES-256-GCM-encrypted table (key
//      random per build, XOR-split in the emitted helper, lazy decrypt).
//   C. Bun.Transpiler whitespace re-minify (stage B re-indents the code),
//      then an acorn re-parse gates the output. Any stage failing throws —
//      never emit an unprotected artifact silently.
//
// Skips keep semantics: module specifiers, import attributes, directives,
// `__proto__` property keys (computed keys would change prototype
// semantics), and oversized literals (bounded ciphertext growth).
import { createCipheriv, randomBytes } from "node:crypto";
import { parse } from "acorn";
import { walk } from "estree-walker";
import { generate } from "astring";
import JavaScriptObfuscator from "javascript-obfuscator";

const MAX_PLAIN_CHARS = 65_536;
const PARSE_OPTS = { ecmaVersion: "latest", sourceType: "module" } as const;

export interface ProtectStats {
  profile: "safe" | "max";
  sites: number;
  unique: number;
  skipped: Record<string, number>;
  bytesIn: number;
  bytesOut: number;
  msObfuscate: number;
  msEncrypt: number;
}

type AstNode = { type: string; [field: string]: any };

function obfuscate(code: string, profile: "safe" | "max"): string {
  const heavy = profile === "max";
  return JavaScriptObfuscator.obfuscate(code, {
    compact: true,
    // Strings are owned by stage B's AES table; the obfuscator's own string
    // array would only add startup cost on top of it.
    stringArray: false,
    controlFlowFlattening: heavy,
    controlFlowFlatteningThreshold: heavy ? 0.75 : 0,
    numbersToExpressions: heavy,
    deadCodeInjection: false,
    selfDefending: false,
    debugProtection: false,
    renameGlobals: false,
    unicodeEscapeSequence: false,
    simplify: true,
    // "hexadecimal" would rename every local to a _0x-style name and add
    // ~1 MB to the bundle; mangled keeps them short.
    identifierGenerator: "mangled",
  }).getObfuscatedCode();
}

function stringValue(node: AstNode): string | undefined {
  if (node.type === "Literal" && typeof node.value === "string") return node.value;
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    const cooked = node.quasis[0]?.value?.cooked;
    if (typeof cooked === "string") return cooked;
  }
  return undefined;
}

function skipReason(
  parent: AstNode,
  prop: string,
  keyPosition: boolean,
  value: string,
): string | null {
  const specifier =
    (prop === "source" &&
      (parent.type === "ImportDeclaration" ||
        parent.type === "ExportNamedDeclaration" ||
        parent.type === "ExportAllDeclaration")) ||
    ((prop === "imported" || prop === "exported") &&
      (parent.type === "ImportSpecifier" ||
        parent.type === "ExportSpecifier" ||
        parent.type === "ExportAllDeclaration")) ||
    parent.type === "ImportAttribute" ||
    (prop === "arguments" &&
      parent.type === "CallExpression" &&
      (parent.callee.type === "Import" ||
        (parent.callee.type === "Identifier" && parent.callee.name === "require")));
  if (specifier) return "specifier";
  if (prop === "expression" && parent.type === "ExpressionStatement" && typeof parent.directive === "string")
    return "directive";
  if (keyPosition && value === "__proto__") return "proto";
  if (value.length > MAX_PLAIN_CHARS) return "oversize";
  return null;
}

function uniquePrefix(code: string): string {
  // Every one of the ~100k call sites carries this prefix; keep it short
  // and regenerate on any collision with existing code.
  for (;;) {
    const candidate = `_${randomBytes(2).toString("hex")}`;
    if (!code.includes(candidate)) return candidate;
  }
}

function decryptHelper(prefix: string, table: string[]): string {
  const key = randomBytes(32);
  const mask = randomBytes(32);
  const masked = Buffer.alloc(32);
  for (let i = 0; i < 32; i++) masked[i] = key[i]! ^ mask[i]!;
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(table), "utf8")),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  const d = `${prefix}_d`;
  return `import { createDecipheriv as ${prefix}_dc } from "node:crypto";
const ${prefix}_a=[${masked.join(",")}],${prefix}_b=[${mask.join(",")}],${prefix}_c="${ciphertext.toString("base64")}",${prefix}_g="${tag.toString("base64")}",${prefix}_n="${nonce.toString("base64")}";
let ${prefix}_t=null;
function ${d}(i){
if(${prefix}_t===null){
const k=Buffer.alloc(32);
for(let j=0;j<32;j++)k[j]=${prefix}_a[j]^${prefix}_b[j];
const dec=${prefix}_dc("aes-256-gcm",k,Buffer.from(${prefix}_n,"base64"));
dec.setAuthTag(Buffer.from(${prefix}_g,"base64"));
${prefix}_t=JSON.parse(Buffer.concat([dec.update(Buffer.from(${prefix}_c,"base64")),dec.final()]).toString("utf8"));
}
return ${prefix}_t[i];
}`;
}

function encryptStrings(code: string): { code: string; sites: number; unique: number; skipped: Record<string, number> } {
  const ast = parse(code, PARSE_OPTS) as unknown as AstNode;
  const prefix = uniquePrefix(code);
  const table: string[] = [];
  const indices = new Map<string, number>();
  const skipped = new Map<string, number>();
  let sites = 0;
  const lookup = (value: string): number => {
    const existing = indices.get(value);
    if (existing !== undefined) return existing;
    const index = table.length;
    table.push(value);
    indices.set(value, index);
    return index;
  };
  walk(ast as any, {
    enter(
      node: any,
      parent: any,
      prop: string | number | symbol | null | undefined,
      index: number | null | undefined,
    ) {
      if (parent === null || parent === undefined || typeof prop !== "string") return;
      const value = stringValue(node);
      if (value === undefined) return;
      const keyPosition =
        prop === "key" &&
        parent.computed === false &&
        (parent.type === "Property" || parent.type === "MethodDefinition" || parent.type === "PropertyDefinition");
      const reason = skipReason(parent, prop, keyPosition, value);
      if (reason !== null) {
        skipped.set(reason, (skipped.get(reason) ?? 0) + 1);
        return;
      }
      const replacement = {
        type: "CallExpression",
        callee: { type: "Identifier", name: `${prefix}_d` },
        arguments: [{ type: "Literal", value: lookup(value), raw: undefined }],
        optional: false,
      };
      if (keyPosition) {
        parent.key = replacement;
        parent.computed = true;
      } else if (index === null || index === undefined) {
        // estree-walker passes null (not undefined) for non-array positions.
        parent[prop] = replacement;
      } else {
        parent[prop][index] = replacement;
      }
      sites++;
    },
  });
  if (sites === 0) return { code, sites, unique: 0, skipped: Object.fromEntries(skipped) };
  return {
    code: `${decryptHelper(prefix, table)}\n${generate(ast as any)}`,
    sites,
    unique: table.length,
    skipped: Object.fromEntries(skipped),
  };
}

export function protect(input: string): { code: string; stats: ProtectStats } {
  const profile = process.env.CETAS_OBFUSCATION === "max" ? "max" : "safe";
  let t = performance.now();
  const obfuscated = obfuscate(input, profile);
  const msObfuscate = performance.now() - t;
  t = performance.now();
  const encrypted = encryptStrings(obfuscated);
  const msEncrypt = performance.now() - t;
  // astring re-indents; compact again (whitespace only — identifiers keep
  // their stage-0 minified names). The `minify` option exists at runtime
  // (verified) but is missing from this @types/bun revision.
  const code = new Bun.Transpiler({
    loader: "js",
    target: "node",
    minify: { whitespace: true, identifiers: false, syntax: false },
  } as ConstructorParameters<typeof Bun.Transpiler>[0]).transformSync(encrypted.code);
  // Syntax gate: the protected artifact must still parse as ESM.
  parse(code, PARSE_OPTS);
  return {
    code,
    stats: { profile, bytesIn: Buffer.byteLength(input), bytesOut: Buffer.byteLength(code), msObfuscate, msEncrypt, sites: encrypted.sites, unique: encrypted.unique, skipped: encrypted.skipped },
  };
}
