// Bun extension subprocess. stdin/stdout are a framed JSONL protocol;
// all extension diagnostics go to stderr, never to the RPC stream.
// Neither this guest nor its caller is the Agent: Posoco owns tool decisions.
import { readFile, realpath, stat } from "node:fs/promises";
// pi_host_compat.mjs is embedded immediately before this worker by bun.go.
// Its imports supply join/resolve/sep/dirname/extname/pathToFileURL to this
// combined module. Reimporting those names causes a Bun ESM syntax error.
import { createInterface } from "node:readline";

const home = process.argv[2];
const cwd = process.argv[3];
const root = join(home, ".cetas", "pi-packages");
const allowlist = join(home, ".cetas", "pi-packages.json");
const tools = new Map();
const activeTools = new Set();
const observers = new Map();
const commands = new Map();
let commandGeneration = 0;
let activeCommandNotices = null;
let generation = 0;
const warnings = [];
const originalLog = console.log;
console.log = (...args) => console.error(...args);
console.info = (...args) => console.error(...args);
function send(message) { process.stdout.write(JSON.stringify(message) + "\n"); }
function fail(reason) { return { ok: false, content: String(reason) }; }
function allTools() { return [...tools.values()].map(({name,description,parameters}) => ({name,description,parameters})); }
function catalog() { return allTools().filter(def => activeTools.has(def.name)); }
function commandCatalog() { return [...commands.values()].map(({definition}) => definition); }
function messageText(message) {
  return Array.isArray(message?.content)
    ? message.content.filter(part => part?.type === "text").map(part => String(part.text ?? "")).join("\n")
    : typeof message?.content === "string" ? message.content : "";
}
function context(notices) {
  return {cwd,hasUI:false,mode:"json",
    sessionManager:{getBranch:()=>[]},
    isIdle:()=>true,
    ui:{
      notify(message) {
        if (notices) notices.push(String(message));
        else warnings.push("Pi UI notification (headless): "+String(message));
      },
      setWidget() { throw new Error("Pi setWidget requires a native UI bridge"); },
    },
  };
}
async function notify(name,payload={}) {
  for (const listener of observers.get(name)??[]) {
    try { await listener({type:name,...payload},context()); }
    catch(e) { warnings.push("Pi event "+name+": "+String(e)); }
  }
}
const passive = new Set(["agent_start","agent_end","agent_settled","turn_start","turn_end","message_start","message_update","message_end","tool_execution_start","tool_execution_end","session_start","session_shutdown"]);
// These Pi hooks mutate Agent or TUI behavior, and cannot be faithfully
// replayed from a passive observer. Accept registration to let other tools
// load, but expose the limitation as diagnostics instead of fabricating it.
const unsupported = new Set(["session_tree","model_select","tool_call","before_agent_start"]);
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
      activeTools.add(def.name);
      generation++;
    },
    on(name,handler) {
      if(typeof handler !== "function") throw new Error("Pi event handler must be callable");
      if(unsupported.has(name)){
        warnings.push("Pi hook "+name+" requires a Posoco kernel bridge; not enabled in headless Bun");
        return () => {};
      }
      if(!passive.has(name)) throw new Error("unsupported Pi event " + name);
      if(!observers.has(name)) observers.set(name,[]);
      observers.get(name).push(handler);
      return () => {
        const handlers = observers.get(name)??[];
        const index=handlers.indexOf(handler);
        if(index>=0) handlers.splice(index,1);
      };
    },
    getAllTools() { return allTools(); },
    getActiveTools() { return [...activeTools]; },
    setActiveTools(names) {
      if(!Array.isArray(names)) throw new Error("setActiveTools requires array");
      for(const name of names) if(!tools.has(name)) throw new Error("unknown Pi tool: "+name);
      activeTools.clear();
      for(const name of names) activeTools.add(name);
      generation++;
    },
    registerCommand(name, def) {
      if (typeof name !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || typeof def?.handler !== "function")
        throw new Error("Pi command requires a simple name and handler(args, ctx)");
      const id = "pi:" + name;
      if (commands.has(id)) throw new Error("duplicate Pi command " + id);
      commands.set(id, { definition: {
        id, label: "/" + id, description: def.description || "", category: "pi",
        ctype: "action", params: [], aliases: [], visible: true,
      }, handler: def.handler, shortcut: false });
      commandGeneration++;
    },
    // Pi messages emitted by a command can be displayed by the native TUI
    // as command feedback. They are not injected into the Posoco journal or
    // silently promoted into a new Agent turn.
    sendMessage(message) {
      const text = messageText(message);
      if (!text) return;
      if (activeCommandNotices) activeCommandNotices.push(text);
      else warnings.push(pkg + ": Pi sendMessage outside a native command cannot be delivered: " + text);
    },
    registerShortcut(key, def) {
      if (typeof key !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9+_-]*$/.test(key) || typeof def?.handler !== "function")
        throw new Error("Pi shortcut requires a key chord and handler(ctx)");
      const id = "pi:#" + key.toLowerCase();
      if (commands.has(id)) throw new Error("duplicate Pi shortcut " + id);
      commands.set(id, { definition: {
        id, label: id, description: def.description || "", category: "pi",
        ctype: "action", params: [], aliases: [], visible: false, shortcut: key.toLowerCase(),
      }, handler: def.handler, shortcut: true });
      commandGeneration++;
    },
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
  // Native scheduler owns model execution; allow Pi tools to bootstrap
  // against the equivalent session-start notification, without a JS Agent.
  await notify("session_start");
}
function textResult(result) {
  if(!result || typeof result !== "object") return fail("Pi tool returned no result");
  const parts = Array.isArray(result.content) ? result.content.filter(x=>x?.type==="text").map(x=>x.text||"") : [];
  return {ok:!result.isError,content:parts.join("\n"),details:result.details};
}
async function dispatch(req) {
  if (req.kind === "command") {
    const entry = commands.get(req.name);
    if (!entry) return {outcome:{type:"failure",reason:"unknown Pi command: "+String(req.name)}};
    const notices = [];
    activeCommandNotices = notices;
    try {
      const result = entry.shortcut
        ? await entry.handler(context(notices))
        : await entry.handler(String(req.args ?? ""), context(notices));
      const feedback = [...notices, ...(typeof result === "string" && result ? [result] : [])].join("\n");
      return {outcome:{type:"success",feedback}};
    } catch (e) {
      return {outcome:{type:"failure",reason:e instanceof Error ? e.message : String(e)}};
    } finally {
      activeCommandNotices = null;
    }
  }
  if(req.kind==="execute") {
    const definition = tools.get(req.name);
    if(!definition) return {result:fail("unknown Pi tool: "+req.name)};
    const ctx = context();
    try {return {result:textResult(await definition.execute(req.callId,req.arguments ?? {},undefined,undefined,ctx))};}
    catch(e) {return {result:fail(e?.stack || String(e))};}
  }
  if(req.kind==="event") {
    const frame = req.frame;
    // Event projection is owned by Go (same adapter as the moejs guest).
    for(const event of req.events ?? []) {
      for(const listener of observers.get(event.type)??[]) {
        try {await listener(event,context());}
        catch(e) {warnings.push("Pi event "+event.type+": "+String(e));}
      }
    }
    return {};
  }
  return {error:"unknown Pi guest RPC: "+String(req.kind)};
}
// Install the Pi host import transform before dynamically importing packages.
// Do not use runtime onResolve for bare specifiers: Bun 1.4.x skips that hook.
const disposePiHostCompat = installPiHostCompat(root);
await boot();
send({kind:"ready",tools:catalog(),generation,commands:commandCatalog(),commandGeneration,warnings});
const lines = createInterface({input:process.stdin,crlfDelay:Infinity});
for await (const line of lines) {
  try {
    const req = JSON.parse(line);
    const response = await dispatch(req);
    send({id:req.id,...response,tools:catalog(),generation,commands:commandCatalog(),commandGeneration,warnings:warnings.splice(0)});
  } catch(e) {
    send({error:String(e)});
  }
}

await notify("session_shutdown");
disposePiHostCompat();
