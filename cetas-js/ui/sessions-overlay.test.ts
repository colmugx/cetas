import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import type { Component } from "@earendil-works/pi-tui";

import {
  SessionsOverlay,
  applySessionTitles,
  listSessionEntries,
  type SessionEntry,
} from "./sessions-overlay.ts";

class FakeTui {
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

function entry(id: string, current = false): SessionEntry {
  return { id, modifiedAt: new Date(), sizeBytes: 1024, current };
}

describe("sessions overlay contract", () => {
  test("listSessionEntries reads jsonl files newest-first and marks current", () => {
    const dir = mkdtempSync(`${tmpdir()}/cetas-sessions-`);
    try {
      writeFileSync(`${dir}/2026-08-25T10-00-00-000Z_old1111.jsonl`, "old");
      writeFileSync(`${dir}/2026-08-26T19-00-00-000Z_new1111.jsonl`, "newer");
      writeFileSync(`${dir}/not-a-session.txt`, "ignored");
      utimesSync(`${dir}/2026-08-25T10-00-00-000Z_old1111.jsonl`, new Date(0), new Date(0));
      utimesSync(`${dir}/2026-08-26T19-00-00-000Z_new1111.jsonl`, new Date(1), new Date(1));
      const entries = listSessionEntries(dir, "2026-08-25T10-00-00-000Z_old1111");
      expect(entries.map((e) => e.id)).toEqual([
        "2026-08-26T19-00-00-000Z_new1111",
        "2026-08-25T10-00-00-000Z_old1111",
      ]);
      expect(entries[0]?.current).toBe(false);
      expect(entries[1]?.current).toBe(true);
      expect(entries[1]?.sizeBytes).toBe(3);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("listSessionEntries treats a missing directory and non-files as empty", () => {
    expect(listSessionEntries(`${tmpdir()}/cetas-missing-${Date.now()}`, "x")).toEqual([]);
    const dir = mkdtempSync(`${tmpdir()}/cetas-sessions-`);
    try {
      // A directory named like a transcript must not produce an entry.
      mkdirSync(`${dir}/2026-08-26T00-00-00-000Z_dirlike.jsonl`);
      expect(listSessionEntries(dir, "x")).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("enter on the highlighted session closes the overlay and returns its id", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    const picked: string[] = [];
    let closed = 0;
    overlay.open(
      [entry("old-session"), entry("new-session")],
      (id) => picked.push(id),
      () => {
        closed++;
      },
    );
    expect(overlay.isActive).toBe(true);
    // Arrow down moves to the second row; enter resumes it.
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual(["new-session"]);
    expect(closed).toBe(1);
    expect(overlay.isActive).toBe(false);
  });

  test("escape closes without resuming anything", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    const picked: string[] = [];
    overlay.open([entry("a"), entry("b")], (id) => picked.push(id), () => {});
    tui.shown!.handleInput!("\u001b");
    expect(picked).toEqual([]);
    expect(overlay.isActive).toBe(false);
  });

  test("overlay renders an explicit empty state and dismisses on any key", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open([], () => {}, () => {});
    const rendered = tui.shown!.render!(80).join("\n");
    expect(rendered).toContain("No sessions found");
    tui.shown!.handleInput!("\r");
    expect(overlay.isActive).toBe(false);
  });

  test("hides the 8-hex uniqueness suffix on timestamp ids but still resumes the full id", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    const picked: string[] = [];
    overlay.open(
      [entry("2026-08-29T12-17-57-155Z_2c30a4ff")],
      (id) => picked.push(id),
      () => {},
    );
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("2026-08-29 12-17-57-155Z");
    expect(rendered).not.toContain("2c30a4ff");
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual(["2026-08-29T12-17-57-155Z_2c30a4ff"]);
  });

  test("keeps ids without the 8-hex uniqueness suffix unchanged", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open(
      [entry("cetas-1756fffffff01234")],
      () => {},
      () => {},
    );
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("cetas-1756fffffff01234");
  });

  test("keeps ids whose trailing underscore run is not exactly 8 lowercase hex", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open(
      [entry("session_ABCDEF12"), entry("run_1234567")],
      () => {},
      () => {},
    );
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("session_ABCDEF12");
    expect(rendered).toContain("run_1234567");
  });
});

describe("applySessionTitles", () => {
  test("titles win over the id-derived label", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open(
      applySessionTitles([entry("2026-08-29T12-17-57-155Z_2c30a4ff")], [
        { id: "2026-08-29T12-17-57-155Z_2c30a4ff", title: "Fix the login bug" },
      ]),
      () => {},
      () => {},
    );
    const rendered = tui.shown!.render!(160).join("\n");
    expect(rendered).toContain("Fix the login bug");
    expect(rendered).not.toContain("2026-08-29 12-17-57-155Z");
  });

  test("entries without a title keep the id-based label", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open(
      applySessionTitles([entry("2026-08-29T12-17-57-155Z_2c30a4ff")], []),
      () => {},
      () => {},
    );
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("2026-08-29 12-17-57-155Z");
  });

  test("merging preserves order and the current marker", () => {
    const old = entry("a-old", true);
    const recent = entry("b-new");
    const merged = applySessionTitles([old, recent], [
      { id: "a-old", title: "Named session" },
      { id: "b-new", title: "Other session" },
    ]);
    expect(merged.map((e) => e.title)).toEqual(["Named session", "Other session"]);
    expect(merged[0]?.current).toBe(true);
    expect(merged[1]?.current).toBe(false);
  });
});
