import { test, expect } from "bun:test";
import { createServer } from "node:net";
import { mkdtempSync, mkdirSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { serveSessionSocket } from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";
import { localOwnerEndpoint, observeLocalOwnerSession } from "./local-session-observer.ts";

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
