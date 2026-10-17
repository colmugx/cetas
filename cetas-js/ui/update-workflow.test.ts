import { describe, expect, test } from "bun:test";
import { CommandRunner } from "./command-runner.ts";
import { UpdateWorkflow, type UpdateWorkflowPorts } from "./update-workflow.ts";

function fixture(check: UpdateWorkflowPorts["check"]) {
  const notices: string[] = [], installs: string[] = [];
  const runner = new CommandRunner(() => {}, () => {});
  let select!: (value: "update" | "command" | "skip" | undefined) => void;
  const workflow = new UpdateWorkflow({
    version: { version: "1.0.0", channel: "npm", manager: "npm" }, home: "/tmp",
    commands: runner, busy: () => runner.busy,
    notice: message => notices.push(message), install: command => installs.push(command), check,
    overlay: { choose: (_v,_latest,_cmd,signal) => new Promise(resolve => {
      select = resolve;
      signal?.addEventListener("abort", () => resolve(undefined), {once:true});
    }) },
  });
  return { runner, workflow, notices, installs, select: (choice: "update"|"command"|"skip"|undefined) => select(choice) };
}

describe("UpdateWorkflow", () => {
  test("up-to-date path releases busy", async () => {
    const f=fixture(async () => undefined);
    await f.workflow.run();
    expect(f.notices).toEqual(["cetas 1.0.0 is up to date"]);
    expect(f.runner.busy).toBe(false);
  });
  test("offline path releases busy", async () => {
    const f=fixture(async () => { throw Error("offline"); });
    await f.workflow.run();
    expect(f.notices).toEqual(["/update failed: offline"]);
    expect(f.runner.busy).toBe(false);
  });
  test("selection remains exclusive until install handoff", async () => {
    const f=fixture(async () => ({latest:"1.0.1",url:"https://example.test"}));
    const work=f.workflow.run();
    await Promise.resolve(); await Promise.resolve();
    expect(f.runner.busy).toBe(true);
    f.select("update");
    await work;
    expect(f.installs).toEqual(["npm install -g @posoco/cetas@latest"]);
    expect(f.runner.busy).toBe(false);
  });
  test("shutdown cancels confirmation without installing", async () => {
    const f=fixture(async () => ({latest:"1.0.1",url:"https://example.test"}));
    const work=f.workflow.run();
    await Promise.resolve(); await Promise.resolve();
    f.runner.cancel();
    await work;
    expect(f.installs).toEqual([]);
    expect(f.runner.busy).toBe(false);
  });
});
