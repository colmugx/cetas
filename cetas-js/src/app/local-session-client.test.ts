import { test, expect } from "bun:test";
import { connect, createServer } from "node:net";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, mkdirSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { localOwnerEndpoint, observeLocalOwner } from "./local-session-client.ts";
import { serveSessionSocket, type SessionEvent } from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";

function event(type: string, cursor: number, busy: boolean): SessionEvent {
  return {
    type, session_id: "s-1", runtime_epoch: "epoch-1", cursor,
    high_water_cursor: cursor, cursor_advance: type !== "session.snapshot",
    busy, ...(type === "assistant.text_delta" ? { delta: "live" } : {}),
  };
}

test("local owner endpoint uses Go-compatible canonical per-home path", () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-owner-home-"));
  try {
    const path = localOwnerEndpoint(home);
    const digest = createHash("sha256").update(
      process.platform === "win32" ? home.toLowerCase() : home,
    ).digest("hex");
    if (process.platform === "win32") {
      expect(path.endsWith(digest.slice(0, 32))).toBe(true);
      expect(path.startsWith("\\\\.\\pipe\\cetas-")).toBe(true);
    } else {
      expect(path).toBe(join(
        "/tmp", `cetas-${process.getuid?.()}-${digest.slice(0, 24)}`, "owner.sock",
      ));
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("Bun viewer discovers live owner, sees working snapshot and stream", async () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-owner-home-"));
  const path = localOwnerEndpoint(home);
  if (process.platform !== "win32") mkdirSync(dirname(path), { mode: 0o700, recursive: true });
  const server = createServer((conn) => {
    void serveSessionSocket(conn, { instanceID: "go-owner", runtimeEpoch: "epoch-1" },
      async (session) => {
        if (session !== "s-1") throw new Error("not owned");
        return {
          snapshot: event("session.snapshot", 6, true),
          events: (async function* () {
            yield event("assistant.text_delta", 7, true);
            yield event("turn.completed", 8, false);
          })(),
          close() {},
        };
      }).catch(() => {});
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, () => { server.off("error", reject); resolve(); });
  });
  if (process.platform !== "win32") chmodSync(path, 0o600);
  try {
    const found = await observeLocalOwner(home, "s-1");
    expect(found.kind).toBe("attached");
    if (found.kind !== "attached") return;
    expect(found.viewer.snapshot.busy).toBe(true);
    const feed = found.viewer.events()[Symbol.asyncIterator]();
    const text = await feed.next();
    expect(text.value?.type).toBe("assistant.text_delta");
    expect(text.value?.delta).toBe("live");
    const done = await feed.next();
    expect(done.value?.type).toBe("turn.completed");
    found.viewer.close();
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    if (process.platform !== "win32") rmSync(dirname(path), { recursive: true, force: true });
    rmSync(home, { recursive: true, force: true });
  }
});

test("absent owner does not create a socket or Agent", async () => {
  const home = mkdtempSync(join(tmpdir(), "cetas-owner-home-"));
  try {
    const found = await observeLocalOwner(home, randomUUID());
    expect(found.kind).toBe("absent");
  } finally { rmSync(home, { recursive: true, force: true }); }
});
