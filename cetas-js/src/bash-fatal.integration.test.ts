import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const childSource = `
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeUnhandledFaultHandler } from "./host-fault.ts";
import * as moonbit from "mbt:colmugx/cetas-js/lib";
const dir = process.env.FAULT_DIR;
const home = join(dir, "home");
const handle = makeUnhandledFaultHandler({
  report(kind, error) {
    writeFileSync(join(dir, "fault.json"), JSON.stringify({ kind, error: String(error) }));
    return "recorded";
  },
  stopSurface() {},
  releaseResources() { moonbit.cetas_js_herdr_release(); },
  writeDiagnostic() {},
  exitFatal() { process.exit(1); },
});
process.on("unhandledRejection", error => handle("unhandled rejection", error));
process.on("uncaughtException", error => handle("uncaught exception", error));
globalThis.fetch = async (url) => {
  if (!String(url).startsWith("http://cetas.test")) return new Response("unavailable", { status: 503 });
  return new Response([
    "data: " + JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: "fatal-bash", type: "function", function: { name: "bash", arguments: JSON.stringify({ cmd: "echo $$ > shell.pid; sleep 30 & echo $! > child.pid; wait" }) } }] } }] }),
    "data: " + JSON.stringify({ choices: [{ finish_reason: "tool_calls" }] }),
    "data: [DONE]",
  ].join("\\n\\n"), { headers: { "content-type": "text/event-stream" } });
};
mkdirSync(join(home, ".cetas"), { recursive: true });
writeFileSync(join(home, ".cetas/settings.json"), JSON.stringify({ providers: { deepseek: { api_key: "test-key", base_url: "http://cetas.test/v1", model: "scripted-model" } } }));
const config = new moonbit.CetasJsConfig(dir, 4, home, "yolo", "");
const runtime = new moonbit.CetasJsRuntime(config);
const agent = await moonbit.cetas_js_runtime_create_agent(runtime, () => {}, () => {}, async () => { throw new Error("unexpected UI"); }, () => false);
void moonbit.cetas_js_run_turn(agent, "run the tool", "[]", "fatal-bash-session", new AbortController().signal);
const deadline = Date.now() + 5000;
while (!existsSync(join(dir, "child.pid"))) {
  if (Date.now() > deadline) throw new Error("bash never started");
  await Bun.sleep(10);
}
Promise.reject(new TypeError("fatal during bash"));
`;

function running(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
  const state = Bun.spawnSync(["ps", "-o", "stat=", "-p", String(pid)]);
  if (state.exitCode !== 0 && state.exitCode !== 1) {
    throw new Error(`ps failed: ${state.stderr.toString()}`);
  }
  const status = state.stdout.toString().trim();
  return status.length > 0 && !status.startsWith("Z");
}

test.if(process.platform !== "win32")("fatal host exit terminates the running bash process and its descendant", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cetas-fatal-bash-test-"));
  const child = Bun.spawn([process.execPath, "--preload", "../moonbit-preload.ts", "--eval", childSource], {
    cwd: import.meta.dir,
    env: { ...process.env, FAULT_DIR: dir, HERDR_ENV: "" },
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  });
  const stderr = new Response(child.stderr).text();
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const code = await Promise.race([
      child.exited,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error("fatal bash host did not exit")), 10_000);
      }),
    ]);
    expect(await stderr).toBe("");
    expect(code).toBe(1);
    expect(JSON.parse(await readFile(join(dir, "fault.json"), "utf8")).error).toBe("TypeError: fatal during bash");
    const shellPid = Number((await readFile(join(dir, "shell.pid"), "utf8")).trim());
    const descendantPid = Number((await readFile(join(dir, "child.pid"), "utf8")).trim());
    const deadline = Date.now() + 1000;
    while ((running(shellPid) || running(descendantPid)) && Date.now() < deadline) await Bun.sleep(20);
    expect(running(shellPid)).toBe(false);
    expect(running(descendantPid)).toBe(false);
  } finally {
    clearTimeout(timeout);
    child.kill();
    await child.exited;
    for (const file of ["child.pid", "shell.pid"]) {
      let text: string;
      try {
        text = await readFile(join(dir, file), "utf8");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw error;
      }
      const pid = Number(text.trim());
      if (Number.isSafeInteger(pid) && pid > 1) {
        try { process.kill(pid, "SIGKILL"); } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
        }
      }
    }
    await rm(dir, { recursive: true, force: true });
  }
}, 15_000);
