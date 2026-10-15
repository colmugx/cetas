import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const childSource = `
import { appendFileSync, writeSync } from "node:fs";
import { ProcessTerminal } from "@earendil-works/pi-tui";
import { makeUnhandledFaultHandler } from "./host-fault.ts";
const record = (entry) => appendFileSync(process.env.FAULT_LOG, JSON.stringify(entry) + "\\n");
const mode = process.env.FAULT_MODE;
const terminal = new ProcessTerminal();
const handle = makeUnhandledFaultHandler({
  report(kind, error) {
    record({ stage: "report", kind, message: String(error), code: error?.code });
    if (mode === "reentrant") handle("uncaught exception", new Error("secondary"));
    if (mode === "logging-fails") throw new Error("log unavailable");
    return "fault recorded";
  },
  stopSurface(broken) {
    record({ stage: "stop", broken });
    try {
      if (!broken) terminal.stop();
      if (mode === "cleanup-throws") throw new Error("stop failed");
    } finally {
      process.stdin.setRawMode?.(false);
      process.stdin.pause();
      record({ stage: "input", isTTY: process.stdin.isTTY, raw: process.stdin.isRaw });
    }
  },
  releaseResources() {
    record({ stage: "release" });
    if (mode === "pending-cleanup") return new Promise(() => {});
  },
  writeDiagnostic(notice) { writeSync(2, notice + "\\n"); },
  exitFatal() { record({ stage: "exit", code: 1 }); process.exit(1); },
});
process.on("unhandledRejection", (error) => handle("unhandled rejection", error));
process.on("uncaughtException", (error) => handle("uncaught exception", error));
terminal.start(() => {}, () => {});
setInterval(() => {}, 1000);
setTimeout(() => {
  if (mode === "epipe") {
    process.stdout.write("broken pipe probe\\n");
  } else if (mode === "exception") {
    throw new TypeError("null.length probe");
  } else {
    Promise.reject(new TypeError("null.length probe"));
  }
}, 30);
`;

async function runFault(mode: string) {
  const dir = await mkdtemp(join(tmpdir(), "cetas-host-fault-test-"));
  const log = join(dir, "fault.jsonl");
  const child = Bun.spawn([process.execPath, "--eval", childSource], {
    cwd: import.meta.dir,
    env: { ...process.env, FAULT_LOG: log, FAULT_MODE: mode, PI_TUI_WRITE_LOG: "" },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const stdout = mode === "epipe"
      ? (await child.stdout.cancel(), Promise.resolve(""))
      : new Response(child.stdout).text();
    const stderr = new Response(child.stderr).text();
    const code = await Promise.race([
      child.exited,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`fatal ${mode} did not exit`)), 2000);
      }),
    ]);
    const entries = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    return { code, entries, stdout: await stdout, stderr: await stderr };
  } finally {
    clearTimeout(timeout);
    child.kill();
    await child.exited;
    await rm(dir, { recursive: true, force: true });
  }
}

describe("host fatal process boundary", () => {
  for (const mode of ["exception", "rejection", "reentrant", "logging-fails", "cleanup-throws", "pending-cleanup"]) {
    test(`${mode} exits without an interrupt despite live input and timers`, async () => {
      const result = await runFault(mode);
      expect(result.code).toBe(1);
      expect(result.entries.filter((entry) => entry.stage === "stop")).toHaveLength(1);
      expect(result.entries.filter((entry) => entry.stage === "release")).toHaveLength(1);
      expect(result.entries.filter((entry) => entry.stage === "exit")).toEqual([{ stage: "exit", code: 1 }]);
      expect(result.entries.filter((entry) => entry.stage === "report" && !entry.kind.startsWith("fatal cleanup"))).toHaveLength(1);
      expect(result.stdout).toContain("\u001b[?2004l");
    });
  }

  test.if(process.platform !== "win32")("restores raw mode on a real pseudo-terminal before exiting", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cetas-host-fault-pty-"));
    const log = join(dir, "fault.jsonl");
    const terminal = new Bun.Terminal({ cols: 100, rows: 30, data: () => {} });
    const initialFlags = terminal.localFlags;
    const child = Bun.spawn([process.execPath, "--eval", childSource], {
      cwd: import.meta.dir,
      env: { ...process.env, FAULT_LOG: log, FAULT_MODE: "exception", PI_TUI_WRITE_LOG: "" },
      terminal,
    });
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      const code = await Promise.race([
        child.exited,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error("PTY fatal did not exit")), 2000);
        }),
      ]);
      const entries = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
      expect(code).toBe(1);
      expect(entries.find((entry) => entry.stage === "input")).toEqual({ stage: "input", isTTY: true, raw: false });
      expect(terminal.localFlags).toBe(initialFlags);
    } finally {
      clearTimeout(timeout);
      child.kill();
      await child.exited;
      terminal.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("a closed stdout exits once without trying to print another notice", async () => {
    const result = await runFault("epipe");
    expect(result.code).toBe(1);
    expect(result.entries.find((entry) => entry.stage === "report").code).toBe("EPIPE");
    expect(result.entries.filter((entry) => entry.stage === "stop")).toEqual([{ stage: "stop", broken: true }]);
    expect(result.entries.filter((entry) => entry.stage === "exit")).toHaveLength(1);
    expect(result.stderr).toBe("");
  });
});
