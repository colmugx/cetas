import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, mkdirSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { serveSessionSocket } from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";
import { localOwnerEndpoint, observeLocalOwnerSession } from "./local-session-observer.ts";

test.skipIf(process.platform === "win32")(
  "independent Go Owner process streams working and live deltas to Bun viewer",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "cetas-go-to-bun-"));
    const endpoint = localOwnerEndpoint(home);
    mkdirSync(dirname(endpoint), { mode: 0o700 });
    let child: ReturnType<typeof spawn> | undefined;
    try {
      const cwd = resolve(import.meta.dir, "../../../cetas-go");
      child = spawn("go", ["run", "../cetas-js/tests/session-bridge-go-owner/main.go",
        endpoint, "idle"], { cwd, stdio: ["pipe", "pipe", "pipe"] });
      const owner = child;
      let stderr = "";
      owner.stderr?.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
      await new Promise<void>((done, fail) => {
        let output = "";
        const timeout = setTimeout(() => fail(new Error("Go Owner did not listen: " + stderr)), 25000);
        owner.stdout?.on("data", (chunk: Buffer) => {
          output += chunk.toString();
          if (output.includes("GO_OWNER_READY")) { clearTimeout(timeout); done(); }
        });
        owner.once("error", (err) => { clearTimeout(timeout); fail(err); });
        owner.once("exit", (code) => {
          clearTimeout(timeout);
          fail(new Error(`Go Owner exited before viewer attachment (${code}): ${stderr}`));
        });
      });
      const viewer = await observeLocalOwnerSession(home, "go-owner-session", "busy");
      if (!viewer) throw new Error("Bun did not attach to separate Go Owner");
      try {
        expect(viewer.snapshot.busy).toBe(false);
        const feed = viewer.events()[Symbol.asyncIterator]();
        owner.stdin?.write("EMIT\\n");
        expect((await feed.next()).value?.type).toBe("turn.accepted");
        const delta = (await feed.next()).value;
        expect(delta?.type).toBe("assistant.text_delta");
        expect(delta?.delta).toBe("Go owner output to Bun");
      } finally {
        viewer.close();
      }
    } finally {
      child?.kill();
      rmSync(dirname(endpoint), { recursive: true, force: true });
      rmSync(home, { recursive: true, force: true });
    }
  },
  35000,
);

test("Bun viewer attached while idle observes the next owner working transition", async () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-idle-observer-"));
  const endpoint = localOwnerEndpoint(home);
  if (process.platform !== "win32") mkdirSync(dirname(endpoint), { mode: 0o700 });
  const server = createServer((socket) => {
    void serveSessionSocket(socket, { instanceID: "go-owner", runtimeEpoch: "epoch-idle" },
      async (sessionID) => {
        if (sessionID !== "session-idle") throw new Error("Session not owned");
        return {
          snapshot: { type: "session.snapshot", session_id: "session-idle",
            runtime_epoch: "epoch-idle", cursor: 0, high_water_cursor: 0, busy: false },
          events: (async function* () {
            yield { type: "turn.started", session_id: "session-idle",
              runtime_epoch: "epoch-idle", cursor: 1, cursor_advance: true };
            yield { type: "assistant.text_delta", session_id: "session-idle",
              runtime_epoch: "epoch-idle", cursor: 2, cursor_advance: true, delta: "new Go output" };
            yield { type: "turn.completed", session_id: "session-idle",
              runtime_epoch: "epoch-idle", cursor: 3, cursor_advance: true };
          })(),
          close() {},
        };
      }).catch(() => {});
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(endpoint, resolve);
    });
    if (process.platform !== "win32") chmodSync(endpoint, 0o600);
    const viewer = await observeLocalOwnerSession(home, "session-idle");
    if (!viewer) throw new Error("missing read-only owner connection");
    try {
      expect(viewer.snapshot.busy).toBe(false);
      const feed = viewer.events()[Symbol.asyncIterator]();
      expect((await feed.next()).value?.type).toBe("turn.started");
      expect((await feed.next()).value?.delta).toBe("new Go output");
      expect((await feed.next()).value?.type).toBe("turn.completed");
    } finally {
      viewer.close();
    }
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    if (process.platform !== "win32") rmSync(dirname(endpoint), { recursive: true, force: true });
    rmSync(home, { recursive: true, force: true });
  }
});

test("Bun discovers same local owner endpoint and sees working + live Session output", async () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-session-observer-"));
  mkdirSync(join(home, ".cetas", "ipc"), { recursive: true, mode: 0o700 });
  const endpoint = localOwnerEndpoint(home);
  if (process.platform !== "win32") mkdirSync(dirname(endpoint), { mode: 0o700 });
  const server = createServer((socket) => {
    void serveSessionSocket(socket, { instanceID: "go-owner", runtimeEpoch: "epoch-one" },
      async (sessionID) => {
        if (sessionID !== "session-one") throw new Error("Session not owned");
        return {
          snapshot: { type: "session.snapshot", session_id: "session-one",
            runtime_epoch: "epoch-one", cursor: 4, high_water_cursor: 4, busy: true },
          events: (async function* () {
            yield { type: "assistant.text_delta", session_id: "session-one",
              runtime_epoch: "epoch-one", cursor: 5, cursor_advance: true, delta: "live text" };
            yield { type: "turn.completed", session_id: "session-one",
              runtime_epoch: "epoch-one", cursor: 6, cursor_advance: true };
          })(),
          close() {},
        };
      }).catch(() => {});
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(endpoint, resolve);
    });
    if (process.platform !== "win32") chmodSync(endpoint, 0o600);
    const viewer = await observeLocalOwnerSession(home, "session-one");
    expect(viewer).toBeDefined();
    if (viewer === undefined) throw new Error("missing owner viewer");
    try {
      expect(viewer.snapshot.busy).toBe(true);
      expect(viewer.owner.runtimeEpoch).toBe("epoch-one");
      const feed = viewer.events()[Symbol.asyncIterator]();
      expect((await feed.next()).value?.delta).toBe("live text");
      expect((await feed.next()).value?.type).toBe("turn.completed");
    } finally {
      viewer.close();
    }
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    if (process.platform !== "win32") rmSync(dirname(endpoint), { recursive: true, force: true });
    rmSync(home, { recursive: true, force: true });
  }
});
