// Unix-only Bun Owner adapter for the shared Posoco Session Bridge.
// Uses the SAME kernel flock file as cetas-go. No daemon or Agent proxy.
// Windows deliberately remains viewer-only until a named-pipe DACL and
// LockFileEx ownership adapter are available.
import { randomUUID } from "node:crypto";
import { constants, closeSync, existsSync, fstatSync, lstatSync, mkdirSync, openSync, chmodSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { dirname, join } from "node:path";
import { dlopen, FFIType } from "bun:ffi";
import { serveSessionSocket, type SessionEvent, type Subscription } from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";
import { localOwnerEndpoint } from "./local-session-observer.ts";

const maxSubscribers = 16;
const maxBufferedEvents = 128;
const flockExclusiveNonblock = 2 | 4;
const flockUnlock = 8;

export type OwnerElection = {
  status: "owner" | "busy" | "disabled" | "unavailable";
  owner?: BunLocalSessionOwner;
};

class EventQueue implements AsyncIterable<SessionEvent> {
  private queue: SessionEvent[] = [];
  private waiter?: (value: IteratorResult<SessionEvent>) => void;
  private closed = false;

  push(event: SessionEvent): void {
    if (this.closed) return;
    if (this.waiter !== undefined) {
      const resolve = this.waiter;
      this.waiter = undefined;
      resolve({ value: event, done: false });
      return;
    }
    if (this.queue.length >= maxBufferedEvents) {
      // Never silently drop a Session event or advance a false cursor.
      this.close();
      return;
    }
    this.queue.push(event);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.queue = [];
    const resolve = this.waiter;
    this.waiter = undefined;
    resolve?.({ value: undefined, done: true });
  }

  async *[Symbol.asyncIterator](): AsyncIterator<SessionEvent> {
    try {
      for (;;) {
        if (this.queue.length > 0) {
          yield this.queue.shift()!;
          continue;
        }
        if (this.closed) return;
        const next = await new Promise<IteratorResult<SessionEvent>>((resolve) => {
          this.waiter = resolve;
        });
        if (next.done) return;
        yield next.value;
      }
    } finally {
      this.close();
    }
  }
}

export class BunLocalSessionOwner {
  readonly runtimeEpoch = randomUUID();
  readonly instanceID = randomUUID();
  private server?: Server;
  private readonly peers = new Set<Socket>();
  private readonly subscribers = new Set<EventQueue>();
  private readonly cursors = new Map<string, number>();
  private sessionID = "";
  private working = false;
  private stopped = false;

  constructor(
    private readonly endpoint: string,
    private readonly releaseLease: () => void,
  ) {}

  start(): void {
    if (this.stopped || this.server !== undefined) return;
    const parent = dirname(this.endpoint);
    if (!existsSync(parent)) mkdirSync(parent, { mode: 0o700 });
    const stat = lstatSync(parent);
    if (!stat.isDirectory() || (stat.mode & 0o077) !== 0 ||
        stat.uid !== process.getuid?.()) {
      throw new Error("unsafe local Session Owner directory");
    }
    // Stale endpoints are not silently unlinked: the Agent may continue
    // independently, but an ambiguous socket cannot claim writer authority.
    if (existsSync(this.endpoint)) throw new Error("local Session endpoint already exists");
    const server = createServer((peer) => {
      if (this.peers.size >= maxSubscribers || this.stopped) {
        peer.destroy();
        return;
      }
      this.peers.add(peer);
      peer.once("close", () => this.peers.delete(peer));
      void serveSessionSocket(peer, {
        instanceID: this.instanceID, runtimeEpoch: this.runtimeEpoch,
      }, async (sessionID) => this.subscribe(sessionID)).catch(() => {
        peer.destroy();
      });
    });
    this.server = server;
    server.on("error", () => {
      // Endpoint failure may not crash a working Agent. The owner lease
      // stays held until shutdown so no second process becomes a writer.
    });
    server.listen(this.endpoint, () => {
      try { chmodSync(this.endpoint, 0o600); } catch { server.close(); }
    });
  }

  update(sessionID: string, busy: boolean): void {
    if (this.stopped) return;
    if (sessionID !== this.sessionID) {
      for (const sub of this.subscribers) sub.close();
      this.subscribers.clear();
      this.sessionID = sessionID;
    }
    this.working = busy;
  }

  private async subscribe(sessionID: string): Promise<Subscription> {
    if (this.stopped || sessionID === "" || sessionID !== this.sessionID) {
      throw new Error("Session not owned by this Bun runtime");
    }
    const events = new EventQueue();
    // Register first; then capture the authoritative high-water cursor and
    // current working state synchronously on the same JS event loop.
    this.subscribers.add(events);
    const cursor = this.cursors.get(sessionID) ?? 0;
    return {
      snapshot: {
        type: "session.snapshot", session_id: sessionID,
        runtime_epoch: this.runtimeEpoch,
        cursor, high_water_cursor: cursor, cursor_advance: false,
        busy: this.working,
      },
      events,
      close: () => {
        this.subscribers.delete(events);
        events.close();
      },
    };
  }

  publish(raw: string): void {
    if (this.stopped || !this.sessionID) return;
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(raw) as Record<string, unknown>;
      if (event === null || Array.isArray(event)) return;
    } catch {
      return;
    }
    const type = event.type;
    let translated: Record<string, unknown>;
    switch (type) {
      case "turn_started":
        this.working = true;
        translated = { type: "turn.started" };
        break;
      case "turn_completed":
        this.working = false;
        translated = { type: "turn.completed" };
        break;
      case "turn_failed":
        this.working = false;
        translated = { type: "turn.failed", message: event.error_message };
        break;
      case "turn_cancelled":
        this.working = false;
        translated = { type: "turn.cancelled" };
        break;
      case "stream_chunk":
        translated = {
          type: event.kind === "reasoning" ? "assistant.reasoning_delta" : "assistant.text_delta",
          delta: event.raw,
        };
        break;
      case "tool_call_started":
        translated = {
          type: "tool.started", tool_call_id: event.tool_call_id,
          tool_name: event.tool_name, args: event.args,
        };
        break;
      case "tool_call_completed":
        translated = {
          type: "tool.completed", tool_call_id: event.tool_call_id,
          result: event.result, is_error: event.is_error,
        };
        break;
      default:
        return;
    }
    const cursor = (this.cursors.get(this.sessionID) ?? 0) + 1;
    this.cursors.set(this.sessionID, cursor);
    const frame = {
      ...translated,
      session_id: this.sessionID,
      runtime_epoch: this.runtimeEpoch,
      cursor, cursor_advance: true,
    } as SessionEvent;
    for (const sub of this.subscribers) sub.push(frame);
  }

  close(): void {
    if (this.stopped) return;
    this.stopped = true;
    for (const sub of this.subscribers) sub.close();
    this.subscribers.clear();
    for (const peer of this.peers) peer.destroy();
    this.peers.clear();
    // The OS closes the descriptor on process crash. Normal shutdown closes
    // the endpoint first; no user-untrusted socket is ever unlinked here.
    this.server?.close();
    this.releaseLease();
  }
}

// A single in-process election does not change Cetas startup semantics.
// If the optional Unix OS lock fails or is unavailable, Cetas runs normally,
// but no local writable Owner endpoint is advertised.
export function electBunLocalOwner(home: string): OwnerElection {
  if (["0", "false", "no", "off"].includes((process.env.CETAS_IPC_OWNER ?? "").trim().toLowerCase())) {
    return { status: "disabled" };
  }
  if (process.platform !== "linux" && process.platform !== "darwin") {
    return { status: "unavailable" };
  }
  let fd: number | undefined;
  try {
    const state = join(home, ".cetas");
    if (!existsSync(state)) mkdirSync(state, { mode: 0o700 });
    const stateStat = lstatSync(state);
    if (!stateStat.isDirectory() || (stateStat.mode & 0o022) !== 0 ||
        stateStat.uid !== process.getuid?.()) throw new Error("unsafe Cetas state directory");
    const privateDir = join(state, "ipc");
    if (!existsSync(privateDir)) mkdirSync(privateDir, { mode: 0o700 });
    const dir = lstatSync(privateDir);
    if (!dir.isDirectory() || (dir.mode & 0o077) !== 0 ||
        dir.uid !== process.getuid?.()) throw new Error("unsafe Cetas lease directory");
    const lockPath = join(privateDir, "owner.lock");
    fd = openSync(lockPath, constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    const info = fstatSync(fd);
    const entry = lstatSync(lockPath);
    if (!info.isFile() || !entry.isFile() || info.ino !== entry.ino ||
        (info.mode & 0o077) !== 0 || info.uid !== process.getuid?.()) {
      throw new Error("unsafe Cetas owner lease");
    }
    const libc = dlopen(
      process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6",
      { flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 } },
    );
    const ownedFD = fd;
    if (libc.symbols.flock(ownedFD, flockExclusiveNonblock) !== 0) {
      closeSync(ownedFD);
      libc.close();
      return { status: "busy" };
    }
    const release = (): void => {
      libc.symbols.flock(ownedFD, flockUnlock);
      closeSync(ownedFD);
      libc.close();
    };
    const owner = new BunLocalSessionOwner(localOwnerEndpoint(home), release);
    try {
      owner.start();
    } catch {
      // Agent still starts: IPC is optional. Keep OS writer authority
      // until the owning process finishes to avoid a successor writer.
    }
    return { status: "owner", owner };
  } catch {
    if (fd !== undefined) closeSync(fd);
    return { status: "unavailable" };
  }
}
