import { createHash, randomUUID } from "node:crypto";
import { realpathSync, lstatSync, statSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { join, dirname } from "node:path";
import {
  observeSessionSocket,
  type SessionViewer,
} from "../../../extension/posoco-ext-session-bridge/ts/bridge.ts";
import { bunOwnerEndpoint } from "./local-session-owner.ts";

// Mirror the existing Cetas Go protected localipc endpoint derivation.
// No endpoint is created and no Agent or journal is touched during probing.
export function localOwnerEndpoint(home: string): string {
  const canonical = realpathSync(home);
  if (process.platform === "win32") {
    const digest = createHash("sha256").update(canonical.toLowerCase()).digest("hex");
    return "\\\\.\\pipe\\cetas-" + digest.slice(0, 32);
  }
  const uid = process.getuid?.();
  if (uid === undefined) throw new Error("local Session owner requires a Unix user identity");
  const digest = createHash("sha256").update(canonical).digest("hex");
  return join("/tmp", `cetas-${uid}-${digest.slice(0, 24)}`, "owner.sock");
}

export type LocalOwnerLookup =
  | { kind: "absent" }
  | { kind: "attached"; viewer: SessionViewer }
  | { kind: "refused"; reason: string };

// A reachable owner may refuse the Session. That is NOT permission to
// open a competing writable journal: callers must fail closed.
export async function observeLocalOwner(
  home: string, sessionID: string, skipOwnBun = false,
): Promise<LocalOwnerLookup> {
  const go = await observeOneLocalOwner(home, sessionID, localOwnerEndpoint);
  if (go.kind === "attached" || skipOwnBun || process.platform === "win32") return go;
  // Go may own a different Session in the same home. A real Bun owner
  // can still own the selected one; probe BOTH safe same-user endpoints.
  const bun = await observeOneLocalOwner(home, sessionID, bunOwnerEndpoint);
  if (bun.kind === "attached") return bun;
  if (go.kind === "refused") return go; // never turn denial into a writer
  return bun;
}

async function observeOneLocalOwner(
  home: string, sessionID: string, endpoint: (home: string) => string,
): Promise<LocalOwnerLookup> {
  let path: string;
  try {
    path = endpoint(home);
  } catch (err) {
    return { kind: "refused", reason: String(err) };
  }
  if (process.platform !== "win32") {
    try {
      const dir = statSync(dirname(path));
      const socket = lstatSync(path);
      if (!dir.isDirectory() || (dir.mode & 0o077) !== 0 ||
          dir.uid !== process.getuid?.() || !socket.isSocket() ||
          (socket.mode & 0o077) !== 0) {
        return { kind: "refused", reason: "unsafe Session owner endpoint permissions" };
      }
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return { kind: "absent" };
      return { kind: "refused", reason: String(err) };
    }
  }
  const socket: Socket = connect(path);
  let attached = false;
  try {
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { cleanup(); reject(new Error("Session owner connect timeout")); }, 1200);
      const cleanup = () => {
        clearTimeout(timeout);
        socket.off("connect", connected);
        socket.off("error", errored);
      };
      const connected = () => { cleanup(); resolve(); };
      const errored = (err: Error) => { cleanup(); reject(err); };
      socket.once("connect", connected);
      socket.once("error", errored);
    });
    try {
      const viewer = await observeSessionSocket(socket, sessionID, randomUUID());
      attached = true;
      return { kind: "attached", viewer };
    } catch (err) {
      return { kind: "refused", reason: String(err) };
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || code === "ECONNREFUSED") {
      return { kind: "absent" };
    }
    return { kind: "refused", reason: String(err) };
  } finally {
    if (!attached) socket.destroy();
  }
}
