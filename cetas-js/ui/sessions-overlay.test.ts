import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import type { Component } from "@earendil-works/pi-tui";

import {
  SessionsOverlay,
  applySessionTitles,
  describeSessionEntry,
  isResumableHere,
  listSessionEntries,
  mergeSessionCatalog,
  sessionsForScope,
  type SessionCatalogEntry,
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
      (entry) => picked.push(entry.id),
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
    overlay.open([entry("a"), entry("b")], (picked_entry) => picked.push(picked_entry.id), () => {});
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
      (picked_entry) => picked.push(picked_entry.id),
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

function foreignEntry(id: string, folder: string, cwd?: string): SessionEntry {
  return {
    id,
    modifiedAt: new Date(),
    sizeBytes: 2048,
    current: false,
    title: `title ${id}`,
    folder,
    inCurrentFolder: false,
    ...(cwd === undefined ? {} : { cwd }),
  };
}

function catalogRow(id: string, dir: string, cwd?: string): SessionCatalogEntry {
  return {
    id,
    title: `catalog ${id}`,
    bucket: dir.split("/").at(-1) ?? dir,
    dir,
    folder: "slug",
    ...(cwd === undefined ? {} : { cwd }),
  };
}

describe("sessions scope toggle", () => {
  test("opens on Current Folder and hides other folders' sessions", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    const picked: string[] = [];
    overlay.open(
      [entry("mine"), foreignEntry("theirs", "other-project", "/work/other-project")],
      (picked_entry) => picked.push(picked_entry.id),
      () => {},
    );
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("[Current Folder]");
    expect(rendered).toContain("mine");
    expect(rendered).not.toContain("theirs");
    // Enter resumes the visible row without any scope change.
    tui.shown!.handleInput!("\r");
    expect(picked).toEqual(["mine"]);
  });

  test("tab switches to All, labels the owning folder, and resumes that row", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    const picked: SessionEntry[] = [];
    overlay.open(
      [entry("mine"), foreignEntry("theirs", "other-project", "/work/other-project")],
      (entry) => picked.push(entry),
      () => {},
    );
    tui.shown!.handleInput!("\t");
    const rendered = tui.shown!.render!(160).join("\n");
    expect(rendered).toContain("[All]");
    expect(rendered).toContain("theirs");
    expect(rendered).toContain("/work/other-project");
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    expect(picked.map((item) => item.id)).toEqual(["theirs"]);
    expect(picked[0]?.inCurrentFolder).toBe(false);
  });

  test("tab toggles back to Current Folder", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open(
      [entry("mine"), foreignEntry("theirs", "other-project", "/work/other-project")],
      () => {},
      () => {},
    );
    tui.shown!.handleInput!("\t");
    tui.shown!.handleInput!("\t");
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("[Current Folder]");
    expect(rendered).not.toContain("theirs");
  });

  test("a foreign session without a recorded folder is flagged as not resumable", () => {
    const legacy = foreignEntry("legacy", "old-project");
    expect(isResumableHere(legacy)).toBe(false);
    expect(isResumableHere(foreignEntry("known", "slug", "/work/known"))).toBe(true);
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open([legacy], () => {}, () => {}, { scope: "all" });
    const rendered = tui.shown!.render!(160).join("\n");
    expect(rendered).toContain("no folder recorded");
    expect(rendered).toContain("old-project");
  });

  test("an empty All scope says so instead of showing the project empty state", () => {
    const tui = new FakeTui();
    const overlay = new SessionsOverlay(tui as never);
    overlay.open([], () => {}, () => {}, { scope: "all" });
    const rendered = tui.shown!.render!(120).join("\n");
    expect(rendered).toContain("No sessions found in any project");
  });
});

describe("mergeSessionCatalog", () => {
  const sessionsDir = "/home/u/.cetas/sessions/session_mine_aaaaaaaaaaaa";
  const otherDir = "/home/u/.cetas/sessions/session_other_bbbbbbbbbbbb";
  const statAt = (times: Record<string, number>) =>
    (path: string) => {
      const ms = times[path];
      return ms === undefined ? undefined : { modifiedAt: new Date(ms), sizeBytes: ms };
    };

  test("mixes folders newest-first and marks only the current session", () => {
    const current: SessionEntry[] = [
      { id: "mine-1", modifiedAt: new Date(1000), sizeBytes: 10, current: true },
    ];
    const merged = mergeSessionCatalog(
      current,
      [
        catalogRow("mine-1", sessionsDir, "/work/mine"),
        catalogRow("other-1", otherDir, "/work/other"),
        catalogRow("legacy-1", otherDir),
      ],
      {
        sessionsDir,
        currentId: "mine-1",
        statFile: statAt({
          [`${sessionsDir}/mine-1.jsonl`]: 1000,
          [`${otherDir}/other-1.jsonl`]: 3000,
          [`${otherDir}/legacy-1.jsonl`]: 2000,
        }),
      },
    );
    expect(merged.map((item) => item.id)).toEqual(["other-1", "legacy-1", "mine-1"]);
    expect(merged[0]?.inCurrentFolder).toBe(false);
    expect(merged[0]?.cwd).toBe("/work/other");
    expect(merged[1]?.cwd).toBeUndefined();
    expect(merged[2]?.inCurrentFolder).toBe(true);
    expect(merged[2]?.current).toBe(true);
    // A legacy foreign row keeps the bucket slug as its label.
    expect(merged[1]?.folder).toBe("slug");
  });

  test("keeps current-folder transcripts the catalog could not parse", () => {
    const current: SessionEntry[] = [
      { id: "broken-1", modifiedAt: new Date(5000), sizeBytes: 3, current: false },
    ];
    const merged = mergeSessionCatalog(current, [catalogRow("ok-1", sessionsDir, "/work/mine")], {
      sessionsDir,
      currentId: "ok-1",
      statFile: statAt({ [`${sessionsDir}/ok-1.jsonl`]: 1000 }),
    });
    expect(merged.map((item) => item.id)).toEqual(["broken-1", "ok-1"]);
    expect(merged[0]?.inCurrentFolder).toBe(true);
    expect(sessionsForScope(merged, "current").map((item) => item.id)).toEqual([
      "broken-1",
      "ok-1",
    ]);
  });

  test("skips catalog rows whose transcript vanished", () => {
    const merged = mergeSessionCatalog([], [catalogRow("gone", otherDir, "/work/gone")], {
      sessionsDir,
      currentId: "x",
      statFile: () => undefined,
    });
    expect(merged).toEqual([]);
  });
});

describe("describeSessionEntry", () => {
  test("All labels every row's folder; Current Folder stays bare", () => {
    const mine: SessionEntry = { ...entry("mine"), folder: "/work/mine" };
    expect(describeSessionEntry(mine, "current").label).not.toContain("/work/mine");
    expect(describeSessionEntry(mine, "current").label).toContain("mine");
    expect(describeSessionEntry(mine, "all").label).toContain("mine  ·  mine");
    const other = foreignEntry("theirs", "slug", "/work/theirs");
    const described = describeSessionEntry(other, "all");
    // The label carries the folder name; the description the full path the
    // resume will use.
    expect(described.label).toContain("theirs");
    expect(described.description).toContain("/work/theirs");
  });
});

describe("wire-shape tolerance", () => {
  test("a catalog row with cwd:null is treated as an unrecorded folder, not a crash", () => {
    const otherDir = "/home/u/.cetas/sessions/session_other_bbbbbbbbbbbb";
    const merged = mergeSessionCatalog(
      [],
      [
        // The MoonBit catalog writes `null` for legacy journals; the overlay
        // must render that row (label + refusal hint) instead of dereferencing
        // the null.
        { ...catalogRow("legacy-row", otherDir), cwd: null },
      ],
      {
        sessionsDir: "/home/u/.cetas/sessions/session_mine_aaaaaaaaaaaa",
        currentId: "x",
        statFile: () => ({ modifiedAt: new Date(1), sizeBytes: 5 }),
      },
    );
    expect(merged).toHaveLength(1);
    expect(merged[0]?.cwd).toBeUndefined();
    expect(isResumableHere(merged[0]!)).toBe(false);
    const described = describeSessionEntry(merged[0]!, "all");
    expect(described.description).toContain("no folder recorded — cannot resume from here");
    // The folder cell falls back to the bucket slug, never to "null".
    expect(described.label).toContain("slug");
    expect(described.description).not.toContain("null");
  });
});
