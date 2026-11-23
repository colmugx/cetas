import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const childSource = `
import { ProcessTerminal } from "@earendil-works/pi-tui";
import { installHostFaultHandler } from "./host-fault.ts";
// Leave the surface running so the process boundary itself must restore input.
installHostFaultHandler();
const terminal = new ProcessTerminal();
terminal.start(() => {}, () => {});
if (!process.stdin.isTTY || !process.stdin.isRaw) process.exit(2);
setInterval(() => {}, 1000);
setTimeout(() => { throw new TypeError("raw mode fault probe"); }, 30);
`;

test.if(process.platform !== "win32")("restores raw mode on a real pseudo-terminal before exiting", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cetas-host-fault-pty-"));
  const terminal = new Bun.Terminal({ cols: 100, rows: 30, data: () => {} });
  const initialFlags = terminal.localFlags;
  const child = Bun.spawn([process.execPath, "--preload", "../moonbit-preload.ts", "--eval", childSource], {
    cwd: import.meta.dir,
    env: { ...process.env, TMPDIR: dir, HERDR_ENV: "", PI_TUI_WRITE_LOG: "" },
    terminal,
  });
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const code = await Promise.race([
      child.exited,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error("PTY fatal did not exit")), 5000);
      }),
    ]);
    expect(code).toBe(1);
    expect(terminal.localFlags).toBe(initialFlags);
    const log = await readFile(join(dir, "cetas-js-crash.log"), "utf8");
    expect(log).toContain("uncaught exception");
    expect(log).toContain("TypeError: raw mode fault probe");
  } finally {
    clearTimeout(timeout);
    child.kill();
    await child.exited;
    terminal.close();
    await rm(dir, { recursive: true, force: true });
  }
}, 10_000);
