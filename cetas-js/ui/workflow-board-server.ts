/**
 * Lightweight localhost presentation of the *existing* Cetas BoardWorkflows.
 * No second backend, no cached task mutations, no browser-side authority.
 */
import { randomBytes } from "node:crypto";
import { createServer, type Server, type IncomingMessage, type ServerResponse } from "node:http";
import { spawn } from "node:child_process";
import type { CetasApplication } from "../src/app/application.ts";

interface BoardServer { server: Server; url: string; }
const boards = new WeakMap<CetasApplication, BoardServer>();
const owners = new Set<BoardServer>();

function applyHeaders(res: ServerResponse): void {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Access-Control-Allow-Origin", "null");
}
function fail(res: ServerResponse, code: number): void {
  res.writeHead(code, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("Request denied");
}
function isLoopbackHost(host: string | undefined, port: number): boolean {
  return host === "127.0.0.1:" + port || host === "localhost:" + port;
}
function parseOutcome(raw: string): unknown {
  const response: unknown = JSON.parse(raw);
  if (typeof response !== "object" || response === null) throw new Error("Invalid Board command response");
  const value = response as Record<string, unknown>;
  if (value.type !== "success") throw new Error("Board is unavailable: " + String(value.reason ?? "unknown"));
  return value.structured;
}
function openInBrowser(url: string): void {
  const platform = process.platform;
  const executable = platform === "win32" ? "cmd" : platform === "darwin" ? "open" : "xdg-open";
  const args = platform === "win32" ? ["/c", "start", "", url] : [url];
  const child = spawn(executable, args, { detached: true, stdio: "ignore", windowsHide: true });
  child.on("error", () => undefined); // The printed URL is a usable fallback.
  child.unref();
}
const HTML = String.raw`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Cetas Board</title>
<style>
:root{color-scheme:dark;font-family:system-ui,sans-serif;background:#10141d;color:#e5ebf4}
body{margin:0;padding:24px;max-width:1800px;margin-inline:auto}h1{font-size:24px;margin:0}
header{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
button{padding:9px 14px;border:1px solid #465268;background:#252f42;color:inherit;border-radius:8px;cursor:pointer}
button:disabled{opacity:.45;cursor:not-allowed}#notice{margin:12px 0;min-height:22px;color:#b7cced}
#meta{color:#acb9ca;margin:16px 0;white-space:pre-wrap}
#lanes{display:grid;grid-template-columns:repeat(7,minmax(185px,1fr));gap:12px;overflow-x:auto;padding-bottom:24px}
.lane{background:#192130;border:1px solid #313d4f;border-radius:10px;padding:10px;min-height:180px}
.lane h2{font-size:15px;font-weight:600;margin:6px 0 12px}.card{background:#263248;border:1px solid #40506b;padding:12px;border-radius:8px;margin-bottom:10px;overflow-wrap:anywhere}
.card h3{font-size:14px;margin:0 0 8px}.muted{color:#a9b8cc;font-size:12px;margin:4px 0}.active{border-color:#82baff}
#details{white-space:pre-wrap;background:#192130;padding:12px;border-radius:8px;min-height:56px}
@media(max-width:900px){#lanes{grid-template-columns:repeat(7,220px)}}
</style></head><body><header><h1>Cetas · Board</h1><div>
<button id="pause">Pause</button><button id="stop">Stop after wave</button><button id="cancel">Cancel agents</button>
</div></header><p id="notice" role="status">Connecting to Cetas…</p><div id="meta"></div>
<main id="lanes"></main><h2>Selected task</h2><div id="details">Select a task card.</div>
<script nonce="__NONCE__">
"use strict";
const secret = new URLSearchParams(location.search).get("token");
if(secret)history.replaceState(null,"",location.pathname);
const stages=["Created","Refining","Ready","Running","Review","Done","Suspended"];
const $ = id => document.getElementById(id);
function text(parent,tag,value,className){const el=document.createElement(tag);el.textContent=String(value??"");if(className)el.className=className;parent.appendChild(el);return el;}
function arr(value){return Array.isArray(value)?value:[];}
function records(value){return arr(value).filter(x=>typeof x==="object"&&x!==null);}
async function request(url,method="GET"){
 const response=await fetch(url,{method,headers:{"Authorization":"Bearer "+secret},cache:"no-store"});
 if(!response.ok)throw new Error("Board request failed ("+response.status+")");
 return response.json();
}
async function refresh(){
 try{
 const envelope=await request("/snapshot");const view=envelope.structured??envelope;
 const board=view.board??{};const flow=view.workflow??{};
 const tasks=records(board.tasks),attempts=records(board.attempts),executions=records(view.executions);
 $("notice").textContent=view.unresolved||view.mutation_uncertain?"Unresolved Board state: execution is blocked. Inspect Cetas.":"Connected · live authoritative Board (refresh 1.5s)";
 $("meta").textContent="Workflow: "+(flow.workflow_id??"none")+" · phase: "+(flow.phase??"idle")+
 " · revision: "+(board.revision??"?")+" · active Agents: "+executions.filter(e=>e.phase==="Running").length+
 " · Tasks: "+tasks.length+"\nBudget: "+JSON.stringify(flow.runner??flow.budgets??{})+
 (view.paused?" · paused":"");
 const lanes=$("lanes");lanes.replaceChildren();
 for(const stage of stages){
 const lane=text(lanes,"section","");lane.className="lane";
 const members=tasks.filter(t=>String(t.stage).toLowerCase()===stage.toLowerCase());
 text(lane,"h2",stage+" · "+members.length);
 for(const task of members){
 const card=text(lane,"button","");card.className="card";card.style.textAlign="left";card.style.width="100%";
 const a=attempts.filter(x=>x.task_id===task.id);
 const e=executions.filter(x=>x.task_id===task.id);
 if(e.some(x=>x.phase==="Running"))card.classList.add("active");
 text(card,"h3",task.title??task.id);
 text(card,"div","Priority: "+(task.priority??"normal"),"muted");
 text(card,"div","Dependencies: "+arr(task.dependencies).join(", "),"muted");
 text(card,"div","Attempts: "+a.map(x=>x.status).join(", "),"muted");
 text(card,"div","Agents: "+e.map(x=>x.phase).join(", "),"muted");
 card.addEventListener("click",()=>{
 $("details").textContent=JSON.stringify({task,attempts:a,executions:e},null,2);
 });
 }
 }
 }catch(error){$("notice").textContent="Disconnected / unable to read Board: "+String(error);}
}
for(const [id,command] of [["pause","pause"],["stop","stop"],["cancel","cancel"]]){
 $(id).addEventListener("click",async()=>{
 if(command==="cancel"&&!confirm("Cancel actual owned Agent executions?"))return;
 try{await request("/control/"+command,"POST");await refresh();}
 catch(error){$("notice").textContent=String(error);}
 });
}
refresh();setInterval(refresh,1500);
</script></body></html>`;

export async function openWorkflowBoard(app: CetasApplication): Promise<string> {
  const previous = boards.get(app);
  if (previous?.server.listening) { openInBrowser(previous.url); return previous.url.split("?")[0]!; }
  const token = randomBytes(32).toString("hex");
  const nonce = randomBytes(24).toString("base64");
  let port = 0;
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    applyHeaders(res);
    if (!isLoopbackHost(req.headers.host, port)) return fail(res, 403);
    if (req.url?.startsWith("/?token=") && req.method==="GET") {
      const url = new URL(req.url, "http://127.0.0.1:"+port);
      if (url.searchParams.get("token") !== token) return fail(res, 403);
      res.setHeader("Content-Security-Policy", "default-src 'none'; connect-src 'self'; script-src 'nonce-"+nonce+"'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
      res.writeHead(200,{"Content-Type":"text/html; charset=utf-8"});
      res.end(HTML.replace("__NONCE__",nonce));
      return;
    }
    if (req.headers.authorization !== "Bearer "+token) return fail(res, 403);
    if(req.headers.origin && req.headers.origin !== "http://127.0.0.1:"+port) return fail(res, 403);
    if(req.url==="/snapshot"&&req.method==="GET"){
      try {
        const result=parseOutcome(await app.invokeCommand("board.workflow.status"));
        res.writeHead(200,{"Content-Type":"application/json; charset=utf-8"});
        res.end(JSON.stringify({structured:result}));
      } catch { fail(res,503); }
      return;
    }
    const controls: Record<string,string> = {
      "/control/pause":"board.workflow.pause",
      "/control/stop":"board.workflow.stop",
      "/control/cancel":"board.workflow.cancel",
    };
    if(req.method==="POST"&&req.url && controls[req.url]){
      try{
        const result=parseOutcome(await app.invokeCommand(controls[req.url]!));
        res.writeHead(200,{"Content-Type":"application/json; charset=utf-8"});
        res.end(JSON.stringify({structured:result}));
      }catch {fail(res,409);}
      return;
    }
    fail(res,404);
  });
  try{
    await new Promise<void>((resolve,reject)=>{
      server.once("error",reject);
      server.listen(0,"127.0.0.1",()=>{server.off("error",reject);resolve();});
    });
    const address=server.address();
    if(!address||typeof address==="string")throw new Error("Board localhost binding failed");
    port=address.port;
    const url="http://127.0.0.1:"+port+"/?token="+token;
    const owner={server,url};boards.set(app,owner);owners.add(owner);
    server.on("close",()=>owners.delete(owner));
    openInBrowser(url);
    return "http://127.0.0.1:"+port+"/";
  }catch(error){server.close();throw error;}
}
export async function closeWorkflowBoards(): Promise<void> {
  const all=[...owners];
  await Promise.all(all.map(owner=>new Promise<void>(resolve=>owner.server.close(()=>resolve()))));
}
