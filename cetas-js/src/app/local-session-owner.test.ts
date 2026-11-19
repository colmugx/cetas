import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BunSessionOwner, bunOwnerEndpoint } from "./local-session-owner.ts";
import { observeLocalOwner } from "./local-session-client.ts";

test("Bun owner publishes existing working and live Agent text to a separate observer", async () => {
  if (process.platform === "win32") return; // Windows Bun ACL not implemented
  const home = mkdtempSync(join(tmpdir(), "cetas-bun-owner-"));
  const state = { sessionID: "s-1", busy: true };
  const owner = new BunSessionOwner(home, () => state);
  try {
    expect(await owner.start()).toBe(true);
    const lookup = await observeLocalOwner(home, "s-1");
    expect(lookup.kind).toBe("attached");
    if (lookup.kind !== "attached") return;
    const viewer = lookup.viewer;
    expect(viewer.snapshot.busy).toBe(true);
    expect(viewer.snapshot.session_id).toBe("s-1");
    const iterator = viewer.events()[Symbol.asyncIterator]();
    owner.publish(JSON.stringify({ type: "turn_started" }));
    owner.publish(JSON.stringify({ type: "stream_chunk", kind: "text", raw: "hello" }));
    state.busy = false;
    owner.publish(JSON.stringify({ type: "turn_completed" }));
    const a = await iterator.next();
    const b = await iterator.next();
    const c = await iterator.next();
    expect(a.value?.type).toBe("turn.started");
    expect(b.value?.type).toBe("assistant.text_delta");
    expect(b.value?.delta).toBe("hello");
    expect(c.value?.type).toBe("turn.completed");
    viewer.close();
  } finally {
    owner.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test("Bun owner refuses unowned Session without composing another writer", async () => {
  if (process.platform === "win32") return;
  const home = mkdtempSync(join(tmpdir(), "cetas-bun-owner-"));
  const owner = new BunSessionOwner(home, () => ({ sessionID: "s-1", busy: true }));
  try {
    await owner.start();
    const bad = await observeLocalOwner(home, "other-session");
    expect(bad.kind).toBe("refused");
    const competing = new BunSessionOwner(home, () => ({ sessionID: "other-session", busy: true }));
    expect(await competing.start()).toBe(false);
    competing.close();
  } finally {
    owner.close();
    rmSync(home, { recursive: true, force: true });
  }
});
