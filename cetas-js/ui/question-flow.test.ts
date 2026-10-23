/**
 * question-flow.test.ts — the shell side of non-blocking asks (`notify_user`):
 * events park and clear the header line, `@qN` routing refuses unknown ids,
 * `/answer` is a no-op with nothing pending, and a refused kind leaves the
 * question pending. Headless: a real TUI over a stub terminal, no app
 * attached — reaching submission would throw, which several tests rely on.
 */

import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TuiMainScreen } from "@earendil-works/pi-tui";

import { TerminalShell } from "./terminal-shell.ts";

function makeShell(): TerminalShell {
  const terminal = {
    write: () => {},
    hideCursor: () => {},
    showCursor: () => {},
    clearScreen: () => {},
    cursorTo: () => {},
    getRows: () => 40,
    getColumns: () => 120,
  };
  const tui = new TuiMainScreen(terminal as never);
  return new TerminalShell({
    tui,
    cwd: "/tmp",
    sessionsDir: mkdtempSync(join(tmpdir(), "cetas-question-test-")),
    maxToolRounds: 8,
    initialSessionId: "2026-09-01T00-00-00-000Z_deadbeef",
  });
}

function askedEvent(questionId: string, shortId: string): string {
  return JSON.stringify({
    type: "question_event",
    label: "question_asked",
    data: {
      question_id: questionId,
      short_id: shortId,
      origin_call: "call-1",
      question: "Upgrade node to 22?",
      kind: "confirm",
      options: [],
      asked_at: 1,
      deadline_at: 0,
    },
  });
}

function closedEvent(questionId: string): string {
  return JSON.stringify({
    type: "question_event",
    label: "question_closed",
    data: { question_id: questionId },
  });
}

function transcript(shell: TerminalShell): string {
  return (shell as any).transcript.render(200).join("\n");
}

describe("non-blocking ask shell flow", () => {
  test("a parked question shows in the live header until closed", () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    const swarm = () => ((shell as any).swarmLines as string[]).join("\n");
    expect(swarm()).toContain("@q1 asks you");
    expect(swarm()).toContain("Upgrade node to 22?");

    (shell as any).handleObserverEvent(closedEvent("question-1"));
    expect(swarm()).not.toContain("@q1");
  });

  test("@qN with no matching pending question is refused before admission", () => {
    const shell = makeShell();
    // No app is attached: if the router ever reached submission this would
    // throw, so the notice proves the early return.
    void (shell as any).submit("@q9 staging");
    expect(transcript(shell)).toContain("@q9 matches no pending question");
  });

  test("/answer with nothing pending is a notice, not an error", () => {
    const shell = makeShell();
    void (shell as any).submit("/answer");
    expect(transcript(shell)).toContain("no questions are waiting");
  });

  test("a reply that cannot map to the question kind asks again", () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    void (shell as any).submit("@q1 maybe");
    expect(transcript(shell)).toContain("wants yes/no");
    // Still pending: the question was not consumed by the refused attempt.
    expect(((shell as any).questions as { size: number }).size).toBe(1);
  });

  test("an id-bound reply on a question nobody can answer fails soft", () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    // answerQuestion reaches requireApp() and throws headlessly; the shell
    // must catch it into a notice, never crash the input loop.
    void (shell as any).submit("@q1 yes");
    expect(transcript(shell)).toContain("answer failed:");
    expect(((shell as any).questions as { size: number }).size).toBe(1);
  });
});

describe("/questions and the reply panel", () => {
  test("/questions with nothing pending is a notice, not a panel", () => {
    const shell = makeShell();
    void (shell as any).submit("/questions");
    expect(transcript(shell)).toContain("no questions are waiting");
    expect((shell as any).askRegion.children).toHaveLength(0);
  });

  test("/answer @q1 opens the reply panel above the editor and submitting answers it", async () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    const done = (shell as any).submit("/answer @q1") as Promise<void>;
    // The panel mounts synchronously inside UiRequestBar.request().
    const panel = (shell as any).askRegion.children[0];
    expect(panel).toBeDefined();
    expect((shell as any).askRegion.render(120).join("\n")).toContain("Upgrade node to 22?");
    panel.settle({ type: "yes" });
    await done;
    // Headless: answerQuestion reaches requireApp() and fails into a notice,
    // but the panel is gone and the attempt was made.
    expect(transcript(shell)).toContain("answer failed:");
    expect((shell as any).askRegion.children).toHaveLength(0);
    expect(((shell as any).questions as { size: number }).size).toBe(1);
  });

  test("cancelling the panel leaves the question pending with no answer attempt", async () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    const done = (shell as any).submit("/answer @q1") as Promise<void>;
    const panel = (shell as any).askRegion.children[0];
    panel.settle({ type: "cancelled" });
    await done;
    expect(transcript(shell)).not.toContain("answer failed:");
    expect((shell as any).askRegion.children).toHaveLength(0);
    expect(((shell as any).questions as { size: number }).size).toBe(1);
  });

  test("an empty text reply keeps the question pending", async () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(
      askedEvent("question-1", "@q1").replace("confirm", "input"),
    );
    const done = (shell as any).submit("/answer @q1") as Promise<void>;
    const panel = (shell as any).askRegion.children[0];
    panel.settle({ type: "text", text: "   " });
    await done;
    expect(transcript(shell)).toContain("stays pending");
    expect(transcript(shell)).not.toContain("answer failed:");
    expect(((shell as any).questions as { size: number }).size).toBe(1);
  });

  test("/questions refuses while another ask owns the reply region", () => {
    const shell = makeShell();
    (shell as any).handleObserverEvent(askedEvent("question-1", "@q1"));
    (shell as any).uiRequestBar = { isActive: () => true };
    void (shell as any).submit("/questions");
    expect(transcript(shell)).toContain("another ask is on screen");
    expect((shell as any).askRegion.children).toHaveLength(0);
  });
});
