import { test, expect } from "bun:test";
import { existsSync, lstatSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { electBunLocalOwner } from "./local-session-owner.ts";
import { localOwnerEndpoint, observeLocalOwnerSession } from "./local-session-observer.ts";

test.skipIf(process.platform === "win32")(
  "Bun owner uses Go-compatible OS lease; Go-format viewer receives working and deltas",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "cetas-bun-owner-"));
    let owner: ReturnType<typeof electBunLocalOwner>["owner"];
    try {
      const elected = electBunLocalOwner(home);
      expect(elected.status).toBe("owner");
      owner = elected.owner;
      if (owner === undefined) throw new Error("Bun owner election failed");
      const second = electBunLocalOwner(home);
      expect(second.status).toBe("busy");
      owner.update("active-session", true);

      const endpoint = localOwnerEndpoint(home);
      const deadline = Date.now() + 3000;
      while (!existsSync(endpoint) || (lstatSync(endpoint).mode & 0o077) !== 0) {
        if (Date.now() > deadline) throw new Error("Bun owner never exposed private Unix endpoint");
        await Bun.sleep(10);
      }
      const viewer = await observeLocalOwnerSession(home, "active-session", second.status);
      expect(viewer).toBeDefined();
      if (viewer === undefined) throw new Error("missing owner attachment");
      try {
        expect(viewer.snapshot.busy).toBe(true);
        expect(viewer.snapshot.runtime_epoch).toBe(owner.runtimeEpoch);
        const feed = viewer.events()[Symbol.asyncIterator]();
        owner.publish(JSON.stringify({ type: "stream_chunk", kind: "text", raw: "live from Bun" }));
        const delta = await feed.next();
        expect(delta.value?.type).toBe("assistant.text_delta");
        expect(delta.value?.delta).toBe("live from Bun");
        owner.publish(JSON.stringify({ type: "turn_completed" }));
        expect((await feed.next()).value?.type).toBe("turn.completed");
      } finally {
        viewer.close();
      }
    } finally {
      owner?.close();
      const endpoint = localOwnerEndpoint(home);
      if (existsSync(dirname(endpoint))) {
        // The listener owns the socket; stop it before cleaning its directory.
        await Bun.sleep(20);
        rmSync(dirname(endpoint), { recursive: true, force: true });
      }
      rmSync(home, { recursive: true, force: true });
    }
  },
);
