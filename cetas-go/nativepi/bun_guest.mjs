// Bun extension subprocess. stdin/stdout are a framed JSONL protocol;
// all extension diagnostics go to stderr, never to the RPC stream.
// Neither this guest nor its caller is the Agent: Posoco owns tool decisions.
import { readFile, realpath, stat } from "node:fs/promises";
// pi_host_compat.mjs is embedded immediately before this worker by bun.go.
// Its imports supply join/resolve/sep/dirname/extname/pathToFileURL to this
// combined module. Reimporting those names causes a Bun ESM syntax error.
import { createInterface } from "node:readline";
import { spawn as spawnBrowser } from "node:child_process";
import { randomUUID } from "node:crypto";

const home = process.argv[2];
const cwd = process.argv[3];
const root = join(home, ".cetas", "pi-packages");
const allowlist = join(home, ".cetas", "pi-packages.json");
const tools = new Map();
const activeTools = new Set();
const observers = new Map();
const commands = new Map();
// Session custom entries are host-owned; the worker holds only unacknowledged
// submissions plus a read-only copy of entries restored by the native store.
let sessionID = "";
let restoredEntries = [];
let pendingEntries = [];
let pendingMessages = [];
const newOutboxID = () => randomUUID();
const entryBranch = () => [...restoredEntries, ...pendingEntries].map(
  e => ({type:"custom",customType:e.customType,data:e.data})
);
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
// Read-only model metadata comes from the real Posoco model picker via a
// session-scoped Harness RPC. No secrets or standalone Pi Agent enter Bun.
let modelSnapshot = Object.freeze({model:undefined,available:Object.freeze([])});
const modelRegistry = Object.freeze({
  getAvailable() { return [...modelSnapshot.available]; },
  getAll() { return [...modelSnapshot.available]; },
  find(provider,id) { return modelSnapshot.available.find(m=>m.provider===provider && m.id===id); },
  isUsingOAuth(_model) { return false; },
  async getApiKeyAndHeaders(_model) {
    return {ok:false,error:"Model credentials are not bridged to the Cetas native Pi guest"};
  },
});
function acceptModelSnapshot(snapshot) {
  if(!snapshot || !Array.isArray(snapshot.slots) || typeof snapshot.active!=="string")
    throw new Error("invalid native Pi model snapshot");
  const available = [];
  const seen = new Set();
  let activeModel;
  for(const slot of snapshot.slots) {
    if(!slot || typeof slot.provider!=="string" || typeof slot.model!=="string" ||
       !slot.provider || !slot.model || typeof slot.id!=="string") continue;
    const id = slot.provider+"/"+slot.model;
    if(seen.has(id)) continue;
    seen.add(id);
    // These are discovery descriptors, not Pi model API implementations.
    const entry = Object.freeze({
      provider:slot.provider, id:slot.model, name:typeof slot.label==="string"?slot.label:slot.model,
      ...(typeof slot.context_window==="number"?{contextWindow:slot.context_window}:{}),
    });
    available.push(entry);
    if(slot.id===snapshot.active) activeModel=entry;
  }
  const previous = modelSnapshot.model;
  modelSnapshot=Object.freeze({model:activeModel,available:Object.freeze(available)});
  return previous?.provider!==activeModel?.provider || previous?.id!==activeModel?.id;
}
function context(notices) {
  return {cwd,hasUI:false,mode:"json",
    model:modelSnapshot.model,
    modelRegistry,
    scopedModels:[],
    sessionManager:{getBranch:entryBranch,getSessionId:()=>sessionID},
    isIdle:()=>true,
    ui:{
      notify(message) {
        if (notices) notices.push(String(message));
        else warnings.push("Pi UI notification (headless): "+String(message));
      },
      select() { throw new Error("Pi interactive selection requires a native UI bridge"); },
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
// tool_call is observer-only: the native kernel already made its tool
// admission decision when tool.started reaches this guest. Pi extensions can
// track nested call IDs, but they cannot block, rewrite, or approve calls.
const passive = new Set(["tool_call","before_agent_start","session_tree","model_select","agent_start","agent_end","agent_settled","turn_start","turn_end","message_start","message_update","message_end","tool_execution_start","tool_execution_end","session_start","session_shutdown"]);
// pi-web-access opens its local Curator UI via pi.exec("open", [url]) on
// macOS or pi.exec("cmd", ["/c", "start", "", url]) on Windows.
// Do not expose an unrestricted subprocess runner through this API: accept
// only these browser-launch shapes and HTTP URLs to the loopback interface.
// The guest already runs with a credential-scrubbed environment.
function curatorBrowserTarget(command, args) {
  if (typeof command !== "string" || !Array.isArray(args))
    throw new Error("Pi browser opener requires a command and argument array");
  const mac = command === "open" && args.length === 1;
  const win = command === "cmd" && args.length === 4 &&
    args[0] === "/c" && args[1] === "start" && args[2] === "";
  if (!mac && !win)
    throw new Error("Pi exec is limited to opening the local Curator browser URL");
  const raw = mac ? args[0] : args[3];
  if (typeof raw !== "string" || raw.length > 4096 || /[\u0000-\u001f\u007f"']/u.test(raw))
    throw new Error("invalid Curator browser URL");
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error("invalid Curator browser URL");
  }
  if (parsed.protocol !== "http:" ||
      !["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname.toLowerCase()) ||
      parsed.username || parsed.password)
    throw new Error("Pi exec may only open a local HTTP Curator URL");
  // Use an argv-only system browser helper; never forward an extension's
  // command to cmd.exe, a shell, or an arbitrary executable.
  if (process.platform === "win32")
    return {file:"rundll32.exe", args:["url.dll,FileProtocolHandler", parsed.href]};
  if (process.platform === "darwin")
    return {file:"open", args:[parsed.href]};
  return {file:"xdg-open", args:[parsed.href]};
}
async function openCuratorBrowser(command, args) {
  let target;
  try {
    target = curatorBrowserTarget(command, args);
  } catch (error) {
    return {code:1, stdout:"", stderr:String(error?.message ?? error), killed:false};
  }
  return await new Promise(resolve => {
    let finished = false;
    let stderr = "";
    let child;
    let timer;
    const finish = (code, killed=false) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve({code, stdout:"", stderr, killed});
    };
    try {
      child = spawnBrowser(target.file, target.args, {
        cwd, env:process.env, windowsHide:true,
        shell:false, stdio:["ignore", "ignore", "pipe"],
      });
    } catch (error) {
      stderr = String(error?.message ?? error);
      finish(1);
      return;
    }
    child.stderr?.on("data", data => { stderr = (stderr + String(data)).slice(-4096); });
    child.on("error", error => {
      stderr = String(error?.message ?? error);
      finish(1);
    });
    child.on("close", code => finish(typeof code === "number" ? code : 1));
    timer = setTimeout(() => {
      stderr ||= "Local browser opener timed out";
      child.kill();
      finish(124, true);
    }, 10000);
  });
}
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
      if(!passive.has(name)) throw new Error("unsupported Pi event " + name);
      if(!observers.has(name)) observers.set(name,[]);
      observers.get(name).push(handler);
      return () => {
        const handlers = observers.get(name)??[];
        const index=handlers.indexOf(handler);
        if(index>=0) handlers.splice(index,1);
      };
    },
    exec(command, args) { return openCuratorBrowser(command, args); },
    appendEntry(customType, data) {
      if(typeof customType !== "string" || !customType || customType.length > 128)
        throw new Error("Pi appendEntry requires a bounded custom type");
      const json = JSON.stringify(data ?? null);
      if(!json || json.length > 262144)
        throw new Error("Pi appendEntry exceeds the 256 KiB entry budget");
      if(pendingEntries.length >= 64)
        throw new Error("Pi appendEntry outbox full (64 entries)");
      pendingEntries.push({id:newOutboxID(),customType,data:JSON.parse(json)});
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
    // Messages with triggerTurn are delivered to the native host's turn
    // admission path. Non-turn notifications are out-of-band UI events. No
    // message is injected into the Agent from inside the Bun subprocess.
    sendMessage(message, options={}) {
      const text = messageText(message);
      if (!text) return;
      if(text.length > 65536) throw new Error("Pi sendMessage exceeds 64 KiB");
      if (activeCommandNotices && options?.triggerTurn !== true) {
        activeCommandNotices.push(text);
        return;
      }
      if(pendingMessages.length >= 64)
        throw new Error("Pi sendMessage outbox full (64 messages)");
      pendingMessages.push({
        id:newOutboxID(),text,
        triggerTurn:options?.triggerTurn===true,
        deliverAs:options?.deliverAs==="followUp"?"followUp":"turn",
        display:message?.display!==false,
      });
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
  if(req.kind==="session") {
    const snapshot = req.snapshot;
    if(!snapshot || typeof snapshot.session_id!=="string" ||
      !Array.isArray(snapshot.entries)) throw new Error("invalid Pi session snapshot");
    sessionID=snapshot.session_id;
    // cetas-js's pi.custom_entries records predate native idempotency IDs:
    // preserve those records when a session moves between JS and Go surfaces.
    restoredEntries=snapshot.entries.filter(e=>
      typeof e?.customType==="string" && e.customType.length>0);
    // Re-run Pi's branch-local restore after the host supplied the journal.
    await notify("session_tree");
    return {};
  }
  if(req.kind==="peek-outbox") {
    return {entries:pendingEntries.slice(),messages:pendingMessages.slice()};
  }
  if(req.kind==="ack-outbox") {
    if(!Array.isArray(req.entryIds) || !Array.isArray(req.messageIds))
      throw new Error("invalid Pi outbox acknowledgement");
    const saved = new Set(req.entryIds);
    restoredEntries.push(...pendingEntries.filter(e=>saved.has(e.id)));
    pendingEntries=pendingEntries.filter(e=>!saved.has(e.id));
    const delivered = new Set(req.messageIds);
    pendingMessages=pendingMessages.filter(e=>!delivered.has(e.id));
    return {};
  }
  if(req.kind==="models") {
    const changed=acceptModelSnapshot(req.snapshot);
    if(changed) await notify("model_select", {model:modelSnapshot.model});
    return {};
  }
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
      // Cetas's earliest observable run boundary corresponds to Pi's
      // before_agent_start callback. Tool changes are published through
      // the existing catalog bridge after this observer batch.
      if (event.type === "agent_start") await notify("before_agent_start");
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
