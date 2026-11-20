// Read-only same-user Go Owner discovery for cetas-js/Bun. This adapter
// never starts an Agent or writes a Session journal on behalf of a viewer.
// The shared protocol lives in posoco-ext-session-bridge, not Malphite.
import { createHash, randomUUID } from "node:crypto";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { join } from "node:path";
import { observeSessionSocket, type SessionViewer } from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";

export function localOwnerEndpoint(home: string): string {
  const canonical = realpathSync(home);
  if (process.platform === "win32") {
    const hash = createHash("sha256").update(canonical.toLowerCase()).digest("hex").slice(0, 32);
    return "\\\\.\\pipe\\cetas-" + hash;
  }
  const uid = process.getuid?.();
  if (uid === undefined) throw new Error("cannot verify local IPC user identity");
  const hash = createHash("sha256").update(canonical).digest("hex").slice(0, 24);
  return join("/tmp", `cetas-${uid}-${hash}`, "owner.sock");
}

function assertPrivateSocket(path: string): void {
  if (process.platform === "win32") return; // Go's named-pipe DACL is authoritative.
  const dir = lstatSync(join(path, ".."));
  const socket = lstatSync(path);
  if (!dir.isDirectory() || !socket.isSocket() ||
      (dir.mode & 0o077) !== 0 || (socket.mode & 0o077) !== 0 ||
      dir.uid !== process.getuid?.() || socket.uid !== process.getuid?.()) {
    throw new Error("unsafe Cetas local Session bridge endpoint");
  }
}

function dialOwner(path: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = connect(path);
    const timeout = setTimeout(() => socket.destroy(new Error("local Session owner connection timed out")), 1500);
    const onError = (error: Error): void => {
      clearTimeout(timeout);
      reject(error);
    };
    socket.once("error", onError);
    socket.once("connect", () => {
      clearTimeout(timeout);
      socket.off("error", onError);
      resolve(socket);
    });
  });
}

// An absent endpoint preserves the normal standalone JS path. A present
// endpoint that rejects a Session MUST NOT fall back to composing that
// Session locally, since it may belong to an active other-process writer.
export async function observeLocalOwnerSession(home: string, sessionID: string): Promise<SessionViewer | undefined> {
  if (!sessionID || ["0", "false", "no", "off"].includes((process.env.CETAS_IPC_OWNER ?? "").trim().toLowerCase())) {
    return undefined;
  }
  const path = localOwnerEndpoint(home);
  if (process.platform !== "win32" && !existsSync(path)) return undefined;
  if (process.platform !== "win32") assertPrivateSocket(path);
  let socket: Socket | undefined;
  try {
    socket = await dialOwner(path);
  } catch (error) {
    if (process.platform === "win32" && (error as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw error;
  }
  socket.setTimeout(3000, () => socket.destroy(new Error("local Session owner did not complete negotiation")));
  try {
    const viewer = await observeSessionSocket(socket, sessionID, randomUUID());
    socket.setTimeout(0);
    return viewer;
  } catch (error) {
    socket.destroy();
    throw error;
  }
}
