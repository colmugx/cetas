import { describe, expect, test } from "bun:test";
import { CommandLock } from "./command-lock.ts";
import { UpdateWorkflow, type UpdateWorkflowPorts } from "./update-workflow.ts";

function harness(check: UpdateWorkflowPorts["check"]) {
  const notices: string[] = [];
  const installs: string[] = [];
  const lock = new CommandLock(() => {}, () => {});
  let close: (() => void) | undefined;
  let choose: ((value: "update" | "command" | "skip") => void) | undefined;
  const workflow = new UpdateWorkflow({
    home: "/tmp",
    version: { version: "1.0.0", channel: "npm", manager: "npm" },
    lock,
    busy: () => lock.isHeld,
    notice: (message) => notices.push(message),
    install: (command) => installs.push(command),
    check,
    overlay: {
      open: (_current, _latest, _cmd, onChoose, onClose) => {
        choose = onChoose;
        close = onClose;
      },
    },
  });
  return { workflow, notices, installs, lock, select: (value: "update" | "command" | "skip") => {
    if (close === undefined || choose === undefined) throw new Error("picker never opened");
    close(); // UpdateOverlay invokes close before forwarding the choice.
    choose(value);
  } };
}

describe("UpdateWorkflow command lifetime", () => {
  test("no update releases the lock and permits the next command", async () => {
    const h = harness(async () => undefined);
    await h.workflow.run();
    expect(h.notices).toEqual(["cetas 1.0.0 is up to date"]);
    expect(h.lock.isHeld).toBe(false);
    h.lock.lease("following command").release();
  });

  test("check failure releases even when the API throws", async () => {
    const h = harness(async () => { throw new Error("offline"); });
    await h.workflow.run();
    expect(h.notices).toEqual(["/update failed: offline"]);
    expect(h.lock.isHeld).toBe(false);
  });

  test("picker holds the lock until closed and can hand off installation", async () => {
    const h = harness(async () => ({ latest: "1.0.1", url: "https://example.test" }));
    await h.workflow.run();
    expect(h.lock.isHeld).toBe(true);
    h.select("update");
    expect(h.lock.isHeld).toBe(false);
    expect(h.installs).toEqual(["npm install -g @posoco/cetas@latest"]);
  });
});
