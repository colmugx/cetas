import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TuiMainScreen } from "@earendil-works/pi-tui";
import { TerminalShell } from "./terminal-shell.ts";

interface ShellProbe {
  commandBusy: boolean;
  workflowCommandActive: boolean;
  editor: { disableSubmit: boolean };
  handleInput(data: string): { consume?: boolean } | undefined;
  invokeCommand(command: string, args: string): Promise<void>;
  requireApp(): unknown;
  renderOutcome(outcome: unknown, command: string): void;
}

function makeShell(directory: string): TerminalShell {
  const terminal = { write() {}, hideCursor() {}, showCursor() {}, clearScreen() {}, cursorTo() {}, getRows: () => 40, getColumns: () => 120 };
  return new TerminalShell({ tui: new TuiMainScreen(terminal as never), cwd: directory,
    sessionsDir: directory, maxToolRounds: 8, initialSessionId: "board-ui-test" });
}

test("Board controls remain keyboard-reachable without releasing command occupancy", async () => {
  const directory = mkdtempSync(join(tmpdir(), "cetas-board-ui-"));
  try {
    const shell = makeShell(directory);
    const probe = shell as unknown as ShellProbe;
    const calls: string[] = [];
    let release!: () => void;
    const parked = new Promise<void>(resolve => { release = resolve; });
    probe.requireApp = () => ({
      listCommands: () => [],
      invokeCommand: async (id: string) => {
        calls.push(id);
        if (id === "board.workflow.propose") await parked;
        return JSON.stringify({ type: "success", feedback: "ok" });
      },
    });
    probe.renderOutcome = () => {};
    const proposal = probe.invokeCommand("/board.workflow.propose", "");
    try {
      expect(probe.commandBusy).toBe(true);
      expect(probe.editor.disableSubmit).toBe(false);
      expect(probe.handleInput("x")).toBeUndefined();
      await shell.submit("/board.workflow.status");
      expect(calls).toEqual(["board.workflow.propose", "board.workflow.status"]);
      expect(probe.commandBusy).toBe(true);
      await expect(shell.submit("/board.workflow.graph.approve")).rejects.toThrow("command is running");
      await expect(shell.submit("ordinary new prompt")).rejects.toThrow("command is running");
    } finally {
      release();
      await proposal;
    }
    expect(probe.commandBusy).toBe(false);
    expect(probe.workflowCommandActive).toBe(false);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("ordinary command occupancy still consumes editor keys", () => {
  const directory = mkdtempSync(join(tmpdir(), "cetas-board-ui-"));
  try {
    const probe = makeShell(directory) as unknown as ShellProbe;
    probe.commandBusy = true;
    expect(probe.handleInput("x")).toEqual({ consume: true });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
