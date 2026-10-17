import { describe, expect, test } from "bun:test";
import { CommandRunner } from "./command-runner.ts";

describe("CommandRunner", () => {
  test("busy spans awaited selection and mutation; concurrent attempts reject", async () => {
    let finishSelection!: () => void;
    const log: string[] = [];
    const runner = new CommandRunner(label => log.push(label), () => log.push("released"));
    const running = runner.run("model", async () => {
      await new Promise<void>(resolve => { finishSelection = resolve; });
      log.push("selected");
    });
    expect(runner.busy).toBe(true);
    await expect(runner.run("other", async () => {})).rejects.toThrow("already running");
    finishSelection();
    await running;
    expect(log).toEqual(["model", "selected", "released"]);
    expect(runner.busy).toBe(false);
  });

  test("abort wakes UI waiters and returns to idle", async () => {
    const runner = new CommandRunner(() => {}, () => {});
    const running = runner.run("model", async signal => {
      await new Promise<void>(resolve => signal.addEventListener("abort", () => resolve(), {once: true}));
    });
    runner.cancel();
    await running;
    expect(runner.busy).toBe(false);
  });

  test("even start errors clean up active state", async () => {
    const runner = new CommandRunner(() => { throw Error("bad terminal"); }, () => {});
    await expect(runner.run("x", async () => {})).rejects.toThrow("bad terminal");
    expect(runner.busy).toBe(false);
  });
});
