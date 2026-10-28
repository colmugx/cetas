/**
 * sessions-all-acceptance.test.ts — independent acceptance checks for GitHub
 * issue 123 (`/sessions` gains `Current Folder || All`).
 *
 * These tests are written from the user story, not from the implementation:
 * they build a real `~/.cetas/sessions` home with sessions from two projects,
 * read it through the real MoonBit cross-project catalog, and drive the real
 * `/sessions` picker (open → tab → arrows → enter) on a headless TUI. Nothing
 * here restates the merge logic; every assertion is a promise the story makes:
 *
 *  1. the picker opens on Current Folder and lists/resumes this project only;
 *  2. All lists every project newest-first and labels each row's folder;
 *  3. entering another project's session switches directory, then resumes;
 *  4. a legacy session is visible but refuses to cross folders;
 *  5. a recorded folder that no longer exists errors without changing session;
 *  6. a host without project switching says so instead of mis-resuming.
 */

import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { TuiMainScreen } from "@earendil-works/pi-tui";
import type { Component } from "@earendil-works/pi-tui";
import {
  cetas_js_session_catalog,
  cetas_js_session_titles,
  cetas_js_sessions_dir,
} from "mbt:colmugx/cetas-js/lib";

import { SessionsOverlay, type SessionCatalogEntry } from "./sessions-overlay.ts";
import { TerminalShell } from "./terminal-shell.ts";

/** Every temp path created by a test; removed in afterEach. */
const cleanup: string[] = [];

afterEach(() => {
  for (const path of cleanup.splice(0)) {
    rmSync(path, { recursive: true, force: true });
  }
});

function tempDir(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `cetas-accept-${tag}-`));
  cleanup.push(dir);
  return dir;
}

interface Fixture {
  home: string;
  cwdA: string;
  cwdB: string;
  sessionsDirA: string;
  sessionsDirB: string;
  /** Newest first in the All view: alphaNew, betaMid, betaLegacy, alphaOld. */
  ids: {
    alphaNew: string;
    betaMid: string;
    betaLegacy: string;
    alphaOld: string;
  };
}

function writeSession(
  sessionsDir: string,
  id: string,
  metadata: Record<string, unknown>,
  text: string,
  when: Date,
): string {
  mkdirSync(sessionsDir, { recursive: true });
  const path = join(sessionsDir, `${id}.jsonl`);
  writeFileSync(
    path,
    [
      JSON.stringify(metadata),
      JSON.stringify({ role: "user", content: [{ type: "text", text }] }),
    ].join("\n") + "\n",
  );
  utimesSync(path, when, when);
  return path;
}

/**
 * Project A holds two sessions (one of them older than everything), project B
 * holds a session with a recorded folder plus a legacy one that has none. The
 * mtimes deliberately interleave the projects, so only a globally sorted list
 * reproduces the expected order.
 */
function makeFixture(): Fixture {
  const home = tempDir("home");
  const cwdA = tempDir("project-a");
  const cwdB = tempDir("project-b");
  const sessionsDirA = cetas_js_sessions_dir(home, cwdA);
  const sessionsDirB = cetas_js_sessions_dir(home, cwdB);
  const ids = {
    alphaNew: "2026-10-05T10-00-00-000Z_aaaaaaa1",
    betaMid: "2026-10-03T10-00-00-000Z_bbbbbbb1",
    betaLegacy: "2026-10-02T10-00-00-000Z_bbbbbbb2",
    alphaOld: "2026-10-01T10-00-00-000Z_aaaaaaa2",
  };
  writeSession(
    sessionsDirA,
    ids.alphaNew,
    { "posoco.title": "Alpha new", "cetas.cwd": cwdA },
    "alpha new turn",
    new Date("2026-10-05T10:00:00Z"),
  );
  writeSession(
    sessionsDirA,
    ids.alphaOld,
    { "posoco.title": "Alpha old", "cetas.cwd": cwdA },
    "alpha old turn",
    new Date("2026-10-01T10:00:00Z"),
  );
  writeSession(
    sessionsDirB,
    ids.betaMid,
    { "posoco.title": "Beta mid", "cetas.cwd": cwdB },
    "beta turn",
    new Date("2026-10-03T10:00:00Z"),
  );
  // Written before `cetas.cwd` existed: visible, but cross-folder resume must
  // not guess its project.
  writeSession(
    sessionsDirB,
    ids.betaLegacy,
    { "posoco.title": "Beta legacy" },
    "beta legacy turn",
    new Date("2026-10-02T10:00:00Z"),
  );
  return { home, cwdA, cwdB, sessionsDirA, sessionsDirB, ids };
}

/** Captures the component the shell hands to the overlay host. */
class CaptureTui {
  shown?: Component;
  renders = 0;

  showOverlay(component: Component) {
    this.shown = component;
    return {
      hide: () => {},
      setHidden: () => {},
      isHidden: () => false,
      focus: () => {},
      unfocus: () => {},
      isFocused: () => true,
    };
  }

  requestRender(): void {
    this.renders++;
  }
}

interface StubApp {
  listCommands(): unknown[];
  state: string;
  snapshot(): unknown;
  setSession(id: string): void;
  shutdown(): Promise<void>;
  sessionTitles(dir: string): Promise<unknown[]>;
  sessionCatalog?(home: string): Promise<readonly SessionCatalogEntry[]>;
}

interface Harness {
  shell: TerminalShell;
  capture: CaptureTui;
  app: StubApp;
  setSessions: string[];
  shutdowns(): number;
  switchCalls: string[];
}

/**
 * Real catalog (MoonBit) → real `/sessions` picker → stub application that
 * records the resume/switch handshakes the host would perform.
 */
function makeHarness(
  fixture: Fixture,
  options: { catalog?: boolean; switchProject?: boolean } = {},
): Harness {
  const terminal = {
    write: () => {},
    hideCursor: () => {},
    showCursor: () => {},
    clearScreen: () => {},
    cursorTo: () => {},
    getRows: () => 40,
    getColumns: () => 200,
  };
  const tui = new TuiMainScreen(terminal as never);
  const setSessions: string[] = [];
  const switchCalls: string[] = [];
  let shutdownCount = 0;
  const app: StubApp = {
    listCommands: () => [],
    state: "ready",
    snapshot: () => ({ state: "ready", setup: { providers: [], warnings: [] } }),
    setSession: (id: string) => setSessions.push(id),
    shutdown: async () => {
      shutdownCount++;
    },
    // Titles come from the MoonBit export in production too (`display_title`):
    // the picker never derives them in TypeScript, so a title-less stub would
    // only exercise the id fallback instead of the single-folder view.
    sessionTitles: async (dir: string) =>
      JSON.parse(await cetas_js_session_titles(dir)) as Array<{ id: string; title: string }>,
    ...(options.catalog === false
      ? {}
      : {
          sessionCatalog: async () =>
            JSON.parse(await cetas_js_session_catalog(fixture.home)) as SessionCatalogEntry[],
        }),
  };
  const shell = new TerminalShell({
    tui,
    cwd: fixture.cwdA,
    home: fixture.home,
    sessionsDir: fixture.sessionsDirA,
    maxToolRounds: 8,
    initialSessionId: fixture.ids.alphaNew,
    ...(options.switchProject === false
      ? {}
      : {
          switchProject: async (cwd: string) => {
            switchCalls.push(cwd);
            const nextApp: StubApp = {
              listCommands: () => [],
              state: "ready",
              snapshot: () => ({ state: "ready", setup: { providers: [], warnings: [] } }),
              setSession: (id: string) => setSessions.push(id),
              shutdown: async () => {},
              sessionTitles: async () => [],
            };
            return {
              app: nextApp as never,
              sessionsDir: cetas_js_sessions_dir(fixture.home, cwd),
            };
          },
        }),
  });
  const capture = new CaptureTui();
  (shell as unknown as { sessionsOverlay: SessionsOverlay }).sessionsOverlay =
    new SessionsOverlay(capture as never);
  (shell as unknown as { attachApplication(app: unknown): void }).attachApplication(app);
  return {
    shell,
    capture,
    app,
    setSessions,
    shutdowns: () => shutdownCount,
    switchCalls,
  };
}

const shellInternals = (shell: TerminalShell) =>
  shell as unknown as {
    openSessionsPicker(): Promise<void>;
    transcript: { render(width: number): string[] };
    sessionId: string;
    cwd: string;
    sessionsDir: string;
    app: unknown;
  };

const renderedPanel = (capture: CaptureTui): string => capture.shown!.render(200).join("\n");

const renderedTranscript = (shell: TerminalShell): string =>
  shellInternals(shell).transcript.render(200).join("\n");

async function openPicker(harness: Harness): Promise<void> {
  await shellInternals(harness.shell).openSessionsPicker();
  if (harness.capture.shown === undefined) throw new Error("the /sessions picker never opened");
}

function press(harness: Harness, key: string): void {
  harness.capture.shown!.handleInput!(key);
}

/** Arrow-key navigation plus enter, exactly what a user does. */
function selectRow(harness: Harness, index: number): void {
  for (let i = 0; i < index; i++) press(harness, "\u001b[B");
  press(harness, "\r");
}

async function waitFor(
  predicate: () => boolean,
  label: string,
  timeoutMs = 3000,
): Promise<void> {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > timeoutMs) {
      throw new Error(`timed out waiting for ${label}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("acceptance: /sessions opens on Current Folder and behaves as before", () => {
  test("lists only this project's sessions, newest first, and resumes in place", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture);
    await openPicker(harness);
    const panel = renderedPanel(harness.capture);

    // Default scope is explicitly Current Folder.
    expect(panel).toContain("[Current Folder]");
    expect(panel).not.toContain("[All]");
    // Only project A's sessions, newest first.
    expect(panel).toContain("Alpha new");
    expect(panel).toContain("Alpha old");
    expect(panel).not.toContain("Beta mid");
    expect(panel).not.toContain("Beta legacy");
    expect(panel.indexOf("Alpha new")).toBeLessThan(panel.indexOf("Alpha old"));

    // Enter on the second row resumes that session; no project switch happens.
    selectRow(harness, 1);
    expect(harness.setSessions).toEqual([fixture.ids.alphaOld]);
    expect(harness.switchCalls).toEqual([]);
    expect(shellInternals(harness.shell).sessionId).toBe(fixture.ids.alphaOld);
    expect(renderedTranscript(harness.shell)).toContain("alpha old turn");
  });

  test("a bridge without the cross-project catalog keeps the single-folder view", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture, { catalog: false });
    await openPicker(harness);
    const panel = renderedPanel(harness.capture);
    expect(panel).toContain("Alpha new");
    expect(panel).not.toContain("Beta mid");
    // Tab still toggles, but there is nothing else to show.
    press(harness, "\t");
    expect(renderedPanel(harness.capture)).not.toContain("Beta mid");
    press(harness, "\u001b");
    expect(
      (shellInternals(harness.shell) as unknown as { sessionsOverlay: SessionsOverlay })
        .sessionsOverlay.isActive,
    ).toBe(false);
  });
});

describe("acceptance: All lists every project globally and labels folders", () => {
  test("tab mixes projects newest-first and shows each row's folder", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture);
    await openPicker(harness);
    press(harness, "\t");
    const panel = renderedPanel(harness.capture);

    expect(panel).toContain("[All]");
    // Sessions from both projects are listed.
    for (const title of ["Alpha new", "Beta mid", "Beta legacy", "Alpha old"]) {
      expect(panel).toContain(title);
    }
    // Global newest-first order across projects (mtimes interleave A and B).
    const ordered = ["Alpha new", "Beta mid", "Beta legacy", "Alpha old"].map((title) =>
      panel.indexOf(title),
    );
    expect(ordered).toEqual([...ordered].sort((a, b) => a - b));
    // Rows name their folder: the recorded path for new sessions, the bucket
    // slug for the legacy one.
    expect(panel).toContain(fixture.cwdA);
    expect(panel).toContain(fixture.cwdB);
    // The legacy row has no recorded cwd, so its label falls back to the
    // project slug recovered from the bucket name.
    expect(panel).toContain(basename(fixture.cwdB));
    // The legacy row says outright why it cannot be resumed from here.
    expect(panel).toContain("no folder recorded — cannot resume from here");
  });

  test("tab toggles back to Current Folder without losing the project view", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture);
    await openPicker(harness);
    press(harness, "\t");
    expect(renderedPanel(harness.capture)).toContain("Beta mid");
    press(harness, "\t");
    const panel = renderedPanel(harness.capture);
    expect(panel).toContain("[Current Folder]");
    expect(panel).not.toContain("Beta mid");
    expect(panel).toContain("Alpha new");
  });
});

describe("acceptance: cross-folder resume (A 方案)", () => {
  test("entering another project's session switches directory, then resumes it", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture);
    await openPicker(harness);
    press(harness, "\t");
    // Row order in All: Alpha new, Beta mid, … → one step down is Beta mid.
    selectRow(harness, 1);

    await waitFor(
      () => shellInternals(harness.shell).sessionId === fixture.ids.betaMid,
      "the cross-folder session to resume",
    );
    // The switch asked for exactly the recorded folder, and the shell adopted
    // that project's bucket and session before the next turn.
    expect(harness.switchCalls).toEqual([fixture.cwdB]);
    expect(shellInternals(harness.shell).cwd).toBe(fixture.cwdB);
    expect(shellInternals(harness.shell).sessionsDir).toBe(fixture.sessionsDirB);
    // The app that will run the next message is the new project's app.
    expect(harness.setSessions).toContain(fixture.ids.betaMid);
    // The previous project's application was released.
    expect(harness.shutdowns()).toBe(1);
    // The user is told, and the resumed history is on screen.
    const transcript = renderedTranscript(harness.shell);
    expect(transcript).toContain(`switched to ${fixture.cwdB}`);
    expect(transcript).toContain("beta turn");
  });

  test("a legacy session is visible in All but refuses to cross folders", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture);
    const before = shellInternals(harness.shell).sessionId;
    await openPicker(harness);
    press(harness, "\t");
    // Row order in All: …, Beta legacy (index 2).
    selectRow(harness, 2);

    await waitFor(
      () => renderedTranscript(harness.shell).includes("no recorded folder"),
      "the legacy refusal notice",
    );
    expect(harness.switchCalls).toEqual([]);
    expect(harness.setSessions).toEqual([]);
    expect(shellInternals(harness.shell).sessionId).toBe(before);
    expect(shellInternals(harness.shell).sessionsDir).toBe(fixture.sessionsDirA);
  });

  test("a recorded folder that no longer exists errors and keeps the current session", async () => {
    const fixture = makeFixture();
    // A project whose directory has been deleted or renamed since the session
    // was recorded; it becomes the newest row of the All view.
    const goneCwd = tempDir("project-gone");
    const goneSessions = cetas_js_sessions_dir(fixture.home, goneCwd);
    const goneId = "2026-10-09T10-00-00-000Z_ccccccc1";
    writeSession(
      goneSessions,
      goneId,
      { "posoco.title": "Gone project", "cetas.cwd": goneCwd },
      "gone turn",
      new Date("2026-10-09T10:00:00Z"),
    );
    rmSync(goneCwd, { recursive: true, force: true });

    const harness = makeHarness(fixture);
    const before = shellInternals(harness.shell).sessionId;
    await openPicker(harness);
    press(harness, "\t");
    // Gone project is the newest session → first row.
    selectRow(harness, 0);

    await waitFor(
      () => renderedTranscript(harness.shell).includes("no longer exists"),
      "the missing-folder error",
    );
    const transcript = renderedTranscript(harness.shell);
    expect(transcript).toContain(`folder ${goneCwd} no longer exists`);
    expect(transcript).toContain(before);
    expect(harness.switchCalls).toEqual([]);
    expect(shellInternals(harness.shell).sessionId).toBe(before);
    expect(shellInternals(harness.shell).cwd).toBe(fixture.cwdA);
  });

  test("a host without project switching refuses instead of resuming in the wrong folder", async () => {
    const fixture = makeFixture();
    const harness = makeHarness(fixture, { switchProject: false });
    const before = shellInternals(harness.shell).sessionId;
    await openPicker(harness);
    press(harness, "\t");
    selectRow(harness, 1);

    await waitFor(
      () => renderedTranscript(harness.shell).includes("cannot switch project directories"),
      "the unsupported-host notice",
    );
    expect(harness.setSessions).toEqual([]);
    expect(shellInternals(harness.shell).sessionId).toBe(before);
  });
});
