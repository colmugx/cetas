import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, lstatSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
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

test.skipIf(process.platform === "win32")(
  "Bun Owner streams a live turn to an independent Go process",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "cetas-bun-to-go-"));
    let owner: ReturnType<typeof electBunLocalOwner>["owner"];
    let child: ReturnType<typeof spawn> | undefined;
    try {
      const elected = electBunLocalOwner(home);
      expect(elected.status).toBe("owner");
      owner = elected.owner;
      if (!owner) throw new Error("cannot elect Bun owner");
      owner.update("active-go-view", true);
      const endpoint = localOwnerEndpoint(home);
      const limit = Date.now() + 5000;
      while (!existsSync(endpoint) || (lstatSync(endpoint).mode & 0o077) !== 0) {
        if (Date.now() > limit) throw new Error("Bun Owner pipe never became private");
        await Bun.sleep(10);
      }
      // A real separate Go process loads only the Posoco bridge client. It
      // does not compose a second Agent, and must observe working instantly.
      const cwd = resolve(import.meta.dir, "../../../cetas-go");
      child = spawn("go", ["run", "../cetas-js/tests/session-bridge-go-viewer/main.go",
        endpoint, "active-go-view"], { cwd, stdio: ["ignore", "pipe", "pipe"] });
      let stderr = "";
      child.stderr?.on("data", (buf: Buffer) => { stderr += buf.toString(); });
      const client = child;
      await new Promise<void>((done, fail) => {
        let stdout = "";
        const timer = setTimeout(() => fail(new Error("Go viewer never attached: " + stderr)), 20000);
        client.stdout?.on("data", (buf: Buffer) => {
          stdout += buf.toString();
          if (stdout.includes("READY")) {
            clearTimeout(timer);
            done();
          }
        });
        client.once("error", (error) => { clearTimeout(timer); fail(error); });
        client.once("exit", (code) => {
          clearTimeout(timer);
          fail(new Error(`Go observer quit before ready (exit ${code}): ${stderr}`));
        });
      });
      owner.publish(JSON.stringify({
        type: "stream_chunk", kind: "text", raw: "live from Bun subprocess owner",
      }));
      await new Promise<void>((done, fail) => {
        const timeout = setTimeout(() => fail(new Error("Go viewer did not receive Bun live stream: " + stderr)), 7000);
        client.once("exit", (code) => {
          clearTimeout(timeout);
          if (code === 0) done();
          else fail(new Error(`Go viewer failed (${code}): ${stderr}`));
        });
      });
    } finally {
      child?.kill();
      owner?.close();
      const endpoint = localOwnerEndpoint(home);
      if (existsSync(dirname(endpoint))) {
        await Bun.sleep(30);
        rmSync(dirname(endpoint), { recursive: true, force: true });
      }
      rmSync(home, { recursive: true, force: true });
    }
  },
  35000,
);
