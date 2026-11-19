// Optional Bun Session owner adapter. Reuses the Posoco read-only bridge;
// it never creates an Agent or exposes a writable Session RPC.
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync, existsSync, lstatSync, mkdirSync, realpathSync, rmSync,
} from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";
import {
  serveSessionSocket,
  type SessionEvent,
  type Subscription,
} from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";

export function bunOwnerEndpoint(home: string): string {
  if (process.platform === "win32") {
    throw new Error("Bun Session owner requires a protected Windows named-pipe ACL");
  }
  const uid = process.getuid?.();
  if (uid === undefined) throw new Error("Bun owner requires a Unix user ID");
  const canonical = realpathSync(home);
  const digest = createHash("sha256").update(canonical).digest("hex").slice(0, 24);
  return join("/tmp", `cetas-bun-${uid}-${digest}`, "owner.sock");
}

type ViewState = { sessionID: string; busy: boolean };
type QueuedObserver = {
  readonly sessionID: string;
  readonly frames: SessionEvent[];
  closed: boolean;
  wake?: () => void;
};

const maxObserverFrames = 128;

// One Bun process can publish only its own currently composed Session.
// A second Bun process cannot bind the same Unix pathname. On Windows we
// intentionally do not publish a pipe without a secure owner ACL.
export class BunSessionOwner {
  readonly instanceID = randomUUID();
  readonly runtimeEpoch = randomUUID();
  private server?: Server;
  private path?: string;
  private readonly clients = new Set<Socket>();
  private readonly viewers = new Set<QueuedObserver>();
  private readonly cursors = new Map<string, number>();

  constructor(private readonly home: string, private readonly current: () => ViewState) {}

  async start(): Promise<boolean> {
    if (process.platform === "win32") return false;
    const path = bunOwnerEndpoint(this.home);
    const parent = join(path, "..");
    mkdirSync(parent, { mode: 0o700, recursive: true });
    const dir = lstatSync(parent);
    if (!dir.isDirectory() || (dir.mode & 0o077) !== 0 ||
        dir.uid !== process.getuid?.()) {
      throw new Error("unsafe local Bun Session owner directory");
    }
    if (existsSync(path)) {
      // An existing or stale endpoint must not be replaced without
      // ownership evidence. Failing the optional service is nonfatal.
      return false;
    }
    const server = createServer((socket) => {
      if (this.clients.size >= 16) { socket.destroy(); return; }
      this.clients.add(socket);
      socket.once("close", () => this.clients.delete(socket));
      void serveSessionSocket(
        socket,
        { instanceID: this.instanceID, runtimeEpoch: this.runtimeEpoch },
        async (sessionID) => this.subscribe(sessionID),
      ).catch(() => socket.destroy());
    });
    try {
      await new Promise<void>((resolve, reject) => {
        const fail = (error: Error) => { server.off("error", fail); reject(error); };
        server.once("error", fail);
        server.listen(path, () => { server.off("error", fail); resolve(); });
      });
      chmodSync(path, 0o600);
      this.server = server;
      this.path = path;
      return true;
    } catch (error) {
      server.close();
      throw error;
    }
  }

  // The existing JS observer emits typed events. Normalize only lifecycle
  // and text chunks, leaving the original Agent and SessionStore authoritative.
  publish(raw: string): void {
    const state = this.current();
    if (state.sessionID.length === 0) return;
    let source: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return;
      source = parsed as Record<string, unknown>;
    } catch { return; }
    const type = source.type;
    let kind: string;
    let fields: Record<string, unknown> = {};
    switch (type) {
      case "turn_started": kind = "turn.started"; break;
      case "turn_completed": kind = "turn.completed"; break;
      case "turn_cancelled": kind = "turn.failed"; fields = { message: "cancelled" }; break;
      case "turn_failed":
        kind = "turn.failed";
        fields = { message: typeof source.error_message === "string" ? source.error_message : "turn failed" };
        break;
      case "stream_chunk":
        if (source.kind !== "text" || typeof source.raw !== "string" || source.raw.length === 0) return;
        kind = "assistant.text_delta";
        fields = { delta: source.raw };
        break;
      default: return;
    }
    const cursor = (this.cursors.get(state.sessionID) ?? 0) + 1;
    this.cursors.set(state.sessionID, cursor);
    const frame: SessionEvent = {
      ...fields, type: kind, session_id: state.sessionID,
      runtime_epoch: this.runtimeEpoch, cursor, cursor_advance: true,
    };
    for (const viewer of this.viewers) {
      if (viewer.closed || viewer.sessionID !== state.sessionID) continue;
      if (viewer.frames.length >= maxObserverFrames) {
        viewer.closed = true;
        viewer.wake?.();
        continue;
      }
      viewer.frames.push(frame);
      viewer.wake?.();
    }
  }

  private subscribe(sessionID: string): Subscription {
    const state = this.current();
    if (sessionID === "" || sessionID !== state.sessionID) {
      throw new Error("Session is not owned by this Bun runtime");
    }
    // Attach first; snapshot reads the cursor after subscribing. Events in
    // between are replayed and filtered by high-water cursor in clients.
    const viewer: QueuedObserver = { sessionID, frames: [], closed: false };
    this.viewers.add(viewer);
    const cursor = this.cursors.get(sessionID) ?? 0;
    const snapshot: SessionEvent = {
      type: "session.snapshot", session_id: sessionID,
      runtime_epoch: this.runtimeEpoch, cursor, high_water_cursor: cursor,
      cursor_advance: false, busy: state.busy,
    };
    return {
      snapshot,
      events: this.drain(viewer),
      close: () => { viewer.closed = true; viewer.wake?.(); this.viewers.delete(viewer); },
    };
  }

  private async *drain(viewer: QueuedObserver): AsyncIterable<SessionEvent> {
    while (!viewer.closed) {
      const frame = viewer.frames.shift();
      if (frame !== undefined) { yield frame; continue; }
      await new Promise<void>((resolve) => { viewer.wake = resolve; });
      viewer.wake = undefined;
    }
  }

  close(): void {
    for (const viewer of this.viewers) { viewer.closed = true; viewer.wake?.(); }
    this.viewers.clear();
    for (const client of this.clients) client.destroy();
    this.clients.clear();
    this.server?.close();
    this.server = undefined;
    if (this.path !== undefined) {
      try {
        const entry = lstatSync(this.path);
        if (entry.isSocket() && (entry.mode & 0o077) === 0) rmSync(this.path);
      } catch { /* already absent */ }
    }
    this.path = undefined;
  }
}
