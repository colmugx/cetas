// Bun extension subprocess. stdin/stdout are a framed JSONL protocol;
// all extension diagnostics go to stderr, never to the RPC stream.
// Neither this guest nor its caller is the Agent: Posoco owns tool decisions.
import { readFile, realpath, stat } from "node:fs/promises";
import { join, resolve, sep, dirname, extname } from "node:path";
import { pathToFileURL } from "node:url";
import { createInterface } from "node:readline";

const home = process.argv[2];
const cwd = process.argv[3];
const root = join(home, ".cetas", "pi-packages");
const allowlist = join(home, ".cetas", "pi-packages.json");
const tools = new Map();
const observers = new Map();
let generation = 0;
const warnings = [];
const originalLog = console.log;
console.log = (...args) => console.error(...args);
console.info = (...args) => console.error(...args);
function send(message) { process.stdout.write(JSON.stringify(message) + "\n"); }
function fail(reason) { return { ok: false, content: String(reason) }; }
function catalog() { return [...tools.values()].map(({name,description,parameters}) => ({name,description,parameters})); }
const passive = new Set(["agent_start","agent_end","agent_settled","turn_start","turn_end","message_start","message_update","message_end","tool_execution_start","tool_execution_end"]);
function validName(n) {
  return typeof n === "string" && /^(?:@[a-zA-Z0-9._-]+\/)?[a-zA-Z0-9._-]+$/.test(n)
    && n.split("/").every(s => s !== "." && s !== "..");
}
function confined(base, path) { return path === base || path.startsWith(base + sep); }
async function packageDir(name) {
  const base = await realpath(root);
  for (const candidate of [join(root,"node_modules",name),join(root,name)]) {
    try {
      const real = await realpath(candidate);
      if (!confined(base,real)) throw new Error("Pi package escapes allowlist root");
      await stat(join(real,"package.json"));
      return real;
    } catch(e) { if(e.code !== "ENOENT") throw e; }
  }
  throw new Error("package.json not found in npm umbrella");
}
async function resolveEntry(path) {
  try {
    const s = await stat(path);
    if(s.isFile()) return path;
    if(s.isDirectory()) {
      try {
        const p = JSON.parse(await readFile(join(path,"package.json"),"utf8"));
        if(typeof p.main === "string" && p.main.startsWith("./"))
          return await resolveEntry(resolve(path,p.main));
      } catch {}
    }
  } catch {}
  for(const p of [path+".js",path+".mjs",path+".ts",join(path,"index.js"),join(path,"index.mjs"),join(path,"index.ts")]) {
    try { if((await stat(p)).isFile()) return p; } catch {}
  }
  throw new Error("no Pi JS/TS entry for " + path);
}
function api(pkg) {
  return {
    registerTool(def) {
      if (!def || typeof def.name !== "string" || typeof def.execute !== "function")
        throw new Error("Pi tool requires name and execute()");
      if(tools.has(def.name)) throw new Error("duplicate Pi tool " + def.name);
      tools.set(def.name, {name:def.name, description:def.description || "", parameters:def.parameters || {type:"object",properties:{}}, execute:def.execute});
      generation++;
    },
    on(name,handler) {
      if(!passive.has(name)) throw new Error("unsupported Pi event " + name);
      if(typeof handler !== "function") throw new Error("Pi event handler must be callable");
      if(!observers.has(name)) observers.set(name,[]);
      observers.get(name).push(handler);
    },
    getAllTools() { return catalog(); },
    getActiveTools() { return [...tools.keys()]; },
    setActiveTools(names) {
      if(!Array.isArray(names)) throw new Error("setActiveTools requires array");
      for(const name of [...tools.keys()]) if(!names.includes(name)) tools.delete(name);
      generation++;
    },
    // Unsupported commands/shortcuts must not become fabricated kernel tools.
    registerCommand(name) { warnings.push(pkg+": command /"+name+" is not bridged to native TUI"); },
    registerShortcut(name) { warnings.push(pkg+": shortcut "+name+" is not bridged to native TUI"); },
  };
}
async function boot() {
  let config;
  try { config = JSON.parse(await readFile(allowlist,"utf8")); }
  catch(e) { warnings.push("Pi allowlist missing or malformed (deny by default): "+String(e)); return; }
  if(!Array.isArray(config.packages)) {warnings.push("Pi allowlist packages is not an array");return;}
  for(const name of config.packages) {
    if(!validName(name)) {warnings.push("invalid Pi allowlist package name "+String(name));continue;}
    try {
      const dir = await packageDir(name);
      const manifest = JSON.parse(await readFile(join(dir,"package.json"),"utf8"));
      if(manifest.name !== name) throw new Error("package name mismatch");
      if(!Array.isArray(manifest.pi?.extensions)) continue;
      for(const spec of manifest.pi.extensions) {
        if(typeof spec !== "string" || !spec.startsWith("./")) throw new Error("unsafe Pi entry "+spec);
        const filename = await resolveEntry(resolve(dir,spec));
        const real = await realpath(filename);
        if(!confined(dir,real)) throw new Error("Pi entry escapes package root");
        const mod = await import(pathToFileURL(real).href);
        if(typeof mod.default !== "function") throw new Error("Pi entry has no default export");
        await mod.default(api(name));
      }
    } catch(e) {warnings.push("Pi package "+name+": "+String(e));}
  }
}
function textResult(result) {
  if(!result || typeof result !== "object") return fail("Pi tool returned no result");
  const parts = Array.isArray(result.content) ? result.content.filter(x=>x?.type==="text").map(x=>x.text||"") : [];
  return {ok:!result.isError,content:parts.join("\n"),details:result.details};
}
async function dispatch(req) {
  if(req.kind==="execute") {
    const definition = tools.get(req.name);
    if(!definition) return {result:fail("unknown Pi tool: "+req.name)};
    const ctx = {cwd,hasUI:false,mode:"json"};
    try {return {result:textResult(await definition.execute(req.callId,req.arguments ?? {},undefined,undefined,ctx))};}
    catch(e) {return {result:fail(e?.stack || String(e))};}
  }
  if(req.kind==="event") {
    const frame = req.frame;
    // Event projection is owned by Go (same adapter as the moejs guest).
    for(const event of req.events ?? []) {
      for(const listener of observers.get(event.type)??[]) {
        try {await listener(event,{cwd,hasUI:false,mode:"json"});}
        catch(e) {warnings.push("Pi event "+event.type+": "+String(e));}
      }
    }
    return {};
  }
  return {error:"unknown Pi guest RPC: "+String(req.kind)};
}
await boot();
send({kind:"ready",tools:catalog(),generation,warnings});
const lines = createInterface({input:process.stdin,crlfDelay:Infinity});
for await (const line of lines) {
  try {
    const req = JSON.parse(line);
    const response = await dispatch(req);
    send({id:req.id,...response,tools:catalog(),generation,warnings:warnings.splice(0)});
  } catch(e) {
    send({error:String(e)});
  }
}
