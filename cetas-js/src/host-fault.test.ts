import { describe, expect, test } from "bun:test";
import type { Terminal } from "@earendil-works/pi-tui";

import {
  makeUnhandledFaultHandler,
  TrackedTerminal,
  type UnhandledFaultHooks,
} from "./host-fault.ts";

/** Records lifecycle, touches nothing — safe in a test process. */
class FakeTerminal implements Terminal {
  stopped = false;
  startedCount = 0;

  start(_onInput: (data: string) => void, _onResize: () => void): void {
    this.startedCount += 1;
    this.stopped = false;
  }

  stop(): void {
    this.stopped = true;
  }

  async drainInput(): Promise<void> {}

  write(_data: string): void {}

  get columns(): number {
    return 80;
  }

  get rows(): number {
    return 24;
  }

  get kittyProtocolActive(): boolean {
    return false;
  }

  moveBy(): void {}

  hideCursor(): void {}

  showCursor(): void {}

  clearLine(): void {}

  clearFromCursor(): void {}

  clearScreen(): void {}

  setTitle(): void {}

  setProgress(): void {}
}

describe("TrackedTerminal", () => {
  test("tracks the last lifecycle transition", () => {
    const inner = new FakeTerminal();
    const terminal = new TrackedTerminal(inner);
    expect(terminal.terminalStopped).toBe(false);

    terminal.start(() => {}, () => {});
    expect(terminal.terminalStopped).toBe(false);
    expect(inner.stopped).toBe(false);

    terminal.stop();
    expect(terminal.terminalStopped).toBe(true);
    expect(inner.stopped).toBe(true);

    // A restart clears the teardown flag along with the inner terminal.
    terminal.start(() => {}, () => {});
    expect(terminal.terminalStopped).toBe(false);
  });

  test("delegates writes and dimensions to the inner terminal", () => {
    const terminal = new TrackedTerminal(new FakeTerminal());
    expect(terminal.columns).toBe(80);
    expect(terminal.rows).toBe(24);
    expect(() => terminal.write("x")).not.toThrow();
  });
});

describe("makeUnhandledFaultHandler", () => {
  function rig(stopped: boolean) {
    const calls = {
      reported: [] as string[],
      surfaced: [] as string[],
      exited: [] as string[],
    };
    const hooks: UnhandledFaultHooks = {
      report: (kind, error) => {
        calls.reported.push(`${kind}:${String(error)}`);
        return `notice(${kind})`;
      },
      surface: (notice) => calls.surfaced.push(notice),
      exitFatal: (notice) => calls.exited.push(notice),
      isTerminalStopped: () => stopped,
    };
    return { calls, handle: makeUnhandledFaultHandler(hooks) };
  }

  test("a live terminal surfaces the notice and keeps the host running", () => {
    const { calls, handle } = rig(false);
    handle("uncaught exception", new Error("boom"));
    expect(calls.reported).toEqual(["uncaught exception:Error: boom"]);
    expect(calls.surfaced).toEqual(["notice(uncaught exception)"]);
    expect(calls.exited).toHaveLength(0);
  });

  test("a torn-down terminal exits fatally instead of surfacing", () => {
    const { calls, handle } = rig(true);
    handle("unhandled rejection", "socket died");
    expect(calls.reported).toEqual(["unhandled rejection:socket died"]);
    expect(calls.exited).toEqual(["notice(unhandled rejection)"]);
    expect(calls.surfaced).toHaveLength(0);
  });
});
