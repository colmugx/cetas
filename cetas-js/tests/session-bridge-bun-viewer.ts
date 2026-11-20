// Cross-process Bun consumer used by the native Harness integration test.
// This is the real Cetas/Bun observer adapter, not an in-memory mock Owner.
// It must never compose a second Agent or open a writable Session journal.
import { observeLocalOwnerSession, localOwnerEndpoint } from "../src/app/local-session-observer.ts";
import { realpathSync } from "node:fs";

const home = process.env.CETAS_HOME;
const sessionID = process.env.CETAS_TEST_SESSION_ID;
if (!home || !sessionID) {
  throw new Error("missing native Owner home/session for Bun observer");
}
const viewer = await observeLocalOwnerSession(home, sessionID, "busy");
if (viewer === undefined) {
  throw new Error("Bun viewer did not connect to the Go Owner: endpoint=" + localOwnerEndpoint(home) + " canonicalHome=" + realpathSync(home));
}
try {
  if (viewer.snapshot.session_id !== sessionID ||
      viewer.snapshot.runtime_epoch !== viewer.owner.runtimeEpoch ||
      viewer.snapshot.busy !== true) {
    throw new Error("Bun viewer did not receive the authoritative working Snapshot");
  }
  console.log("FOREIGN_SNAPSHOT_WORKING");
  let output = "";
  for await (const frame of viewer.events()) {
    if (frame.type === "assistant.text_delta") {
      output += typeof frame.delta === "string" ? frame.delta : "";
      if (output.includes("live from Go owner to Bun")) break;
    }
  }
  if (!output.includes("live from Go owner to Bun")) {
    throw new Error("Go Owner stream ended before Bun saw live assistant text");
  }
  console.log("FOREIGN_STREAM_OK");
} finally {
  viewer.close();
}
