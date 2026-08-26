import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import type { Component } from "@earendil-works/pi-tui";

import { SessionsOverlay, listSessionEntries, type SessionEntry } from "./sessions-overlay.ts";

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
});
