/**
 * Session browser UI for cetas-js.
 *
 * Lists the JSONL transcript files under the project sessions directory and
 * returns the chosen session — the host then repoints the application at it
 * (`setSession`). The overlay reads nothing from the files beyond stat
 * metadata. Selecting a session changes the active session; transcript
 * history remains on disk and is not rendered into the current UI.
 *
 * Sessions are shown in one of two scopes (pi's `Current Folder || All`):
 * `current` lists this project's bucket only, `all` mixes every project's
 * sessions newest-first and labels each row with its owning folder. Rows from
 * another folder are only resumable when their metadata records that folder;
 * the overlay never guesses one from the bucket name.
 */

import { existsSync, readdirSync, statSync } from "node:fs";

import {
  SelectList,
  Text,
  matchesKey,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";

export interface SessionEntry {
  /** Session id — the `.jsonl` filename stem under the sessions directory. */
  id: string;
  /** File mtime; ids are timestamp-prefixed so this tracks conversation time. */
  modifiedAt: Date;
  sizeBytes: number;
  current: boolean;
  /**
   * Display title (MoonBit `display_title`): the user-chosen name or a
   * prefix of the first user message. When absent, the label falls back to
   * the id.
   */
  title?: string;
  /**
   * Project directory recorded in the session metadata (`cetas.cwd`). Absent
   * (or `null`, the wire's explicit "not recorded") for legacy journals; a
   * foreign row without it cannot be resumed from here because the owning
   * directory is unknowable.
   */
  cwd?: string | null;
  /**
   * Folder label for the browser: the recorded cwd, else the project slug
   * recovered from the bucket directory name.
   */
  folder?: string;
  /**
   * Whether this session lives in the active project's bucket. Defaults to
   * true so a plain `listSessionEntries` result is a current-folder list.
   */
  inCurrentFolder?: boolean;
}

/** Which folders the picker browses: this one, or every project's. */
export type SessionsScope = "current" | "all";

/** Minimal shape of the bridge's session titles (`id` → `title`). */
export interface SessionTitleLike {
  id: string;
  title: string;
}

/** One session as reported by the MoonBit cross-project catalog. */
export interface SessionCatalogEntry {
  readonly id: string;
  readonly title: string;
  /** Bucket directory name (`session_<slug>_<hash>`). */
  readonly bucket: string;
  /** Full path of the bucket directory holding the transcript. */
  readonly dir: string;
  /** Slug recovered from the bucket name — the legacy display fallback. */
  readonly folder: string;
  /** Recorded project directory; absent or `null` for legacy journals. */
  readonly cwd?: string | null;
}

/**
 * Merge bridge titles onto listed entries by id. Pure and sync so the picker
 * stays trivially testable; entries without a title keep the id-based label.
 */
export function applySessionTitles(
  entries: readonly SessionEntry[],
  titles: readonly SessionTitleLike[],
): SessionEntry[] {
  const byId = new Map(titles.map((t) => [t.id, t.title]));
  return entries.map((entry) => {
    const title = byId.get(entry.id);
    return title === undefined ? entry : { ...entry, title };
  });
}

/**
 * Session `.jsonl` files under `sessionsDir`, newest first. A missing
 * directory is an empty list (first run); unstatable files are skipped, not
 * fatal — the picker must open even when one transcript is mid-write.
 */
export function listSessionEntries(sessionsDir: string, currentId: string): SessionEntry[] {
  if (!existsSync(sessionsDir)) return [];
  const entries: SessionEntry[] = [];
  for (const name of readdirSync(sessionsDir)) {
    if (!name.endsWith(".jsonl")) continue;
    const id = name.slice(0, -".jsonl".length);
    try {
      const stat = statSync(`${sessionsDir}/${name}`);
      if (!stat.isFile()) continue;
      entries.push({
        id,
        modifiedAt: new Date(stat.mtimeMs),
        sizeBytes: stat.size,
        current: id === currentId,
      });
    } catch {
      // skip unstatable entries
    }
  }
  entries.sort((a, b) => b.modifiedAt.getTime() - a.modifiedAt.getTime());
  return entries;
}

export interface SessionCatalogMergeOptions {
  /** Active project's sessions directory — identifies current-folder rows. */
  sessionsDir: string;
  /** Active session id, so its row keeps the `*` marker. */
  currentId: string;
  /** File stat seam; defaults to the real one. */
  statFile?: (path: string) => { modifiedAt: Date; sizeBytes: number } | undefined;
}

function defaultStatFile(path: string): { modifiedAt: Date; sizeBytes: number } | undefined {
  try {
    const stat = statSync(path);
    if (!stat.isFile()) return undefined;
    return { modifiedAt: new Date(stat.mtimeMs), sizeBytes: stat.size };
  } catch {
    return undefined;
  }
}

/**
 * Fold the cross-project catalog into one picker list: every catalog row
 * carries its folder, mtime and size; sessions the catalog skipped (unreadable
 * metadata) still show up when they live in the current folder, exactly as
 * they do today. Rows are mixed by modification time, newest first.
 */
export function mergeSessionCatalog(
  currentFolderEntries: readonly SessionEntry[],
  catalog: readonly SessionCatalogEntry[],
  options: SessionCatalogMergeOptions,
): SessionEntry[] {
  const statFile = options.statFile ?? defaultStatFile;
  const entries: SessionEntry[] = [];
  const seenCurrent = new Set<string>();
  for (const row of catalog) {
    const inCurrentFolder = row.dir === options.sessionsDir;
    const file = statFile(`${row.dir}/${row.id}.jsonl`);
    if (file === undefined) continue;
    if (inCurrentFolder) seenCurrent.add(row.id);
    // The catalog spells "no folder recorded" as null; rows carry it as an
    // absent value so no consumer has to tell the two absences apart.
    const cwd = recordCwd(row.cwd);
    entries.push({
      id: row.id,
      modifiedAt: file.modifiedAt,
      sizeBytes: file.sizeBytes,
      current: inCurrentFolder && row.id === options.currentId,
      title: row.title,
      folder: cwd ?? row.folder,
      inCurrentFolder,
      ...(cwd === undefined ? {} : { cwd }),
    });
  }
  // Current-folder transcripts the catalog could not parse stay listed with
  // their id label; they are still resumable in place.
  for (const entry of currentFolderEntries) {
    if (seenCurrent.has(entry.id)) continue;
    entries.push({ ...entry, inCurrentFolder: true });
  }
  entries.sort((a, b) => b.modifiedAt.getTime() - a.modifiedAt.getTime());
  return entries;
}

/** Entries visible in one scope; the current-folder scope is the default. */
export function sessionsForScope(
  entries: readonly SessionEntry[],
  scope: SessionsScope,
): SessionEntry[] {
  if (scope === "all") return [...entries];
  return entries.filter((entry) => entry.inCurrentFolder !== false);
}

/**
 * A recorded project directory, normalized: `null`, a missing value, and an
 * empty string all mean "this session did not record one".
 */
export function recordCwd(value: string | null | undefined): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * Whether a row can be resumed from here: rows in the active folder always
 * can (same bucket), foreign rows only when they recorded their directory.
 */
export function isResumableHere(entry: SessionEntry): boolean {
  if (entry.inCurrentFolder !== false) return true;
  return recordCwd(entry.cwd) !== undefined;
}

/** Full folder path for a row (recorded cwd, else the bucket slug). */
export function sessionFolderLabel(entry: SessionEntry): string | undefined {
  const cwd = recordCwd(entry.cwd);
  if (cwd !== undefined) return cwd;
  if (entry.folder !== undefined && entry.folder.length > 0) return entry.folder;
  return undefined;
}

/** Last path segment of a folder: what the row label can afford to print. */
export function sessionFolderName(entry: SessionEntry): string | undefined {
  const full = sessionFolderLabel(entry);
  if (full === undefined) return undefined;
  const trimmed = full.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut < 0 ? trimmed : trimmed.slice(cut + 1);
}

export interface SessionsTui {
  showOverlay(component: Component, options: {
    width?: number | `${number}%`;
    maxHeight?: number | `${number}%`;
    anchor?: "center" | "top-left" | "top-right" | "bottom-left" | "bottom-right" | "top-center" | "bottom-center" | "left-center" | "right-center";
    margin?: number;
  }): OverlayHandle;
  requestRender(): void;
}

const selectTheme: SelectListTheme = {
  selectedPrefix: (value) => theme.accent(value),
  selectedText: (value) => theme.accent(value),
  description: (value) => theme.muted(value),
  scrollInfo: (value) => theme.muted(value),
  noMatch: (value) => theme.error(value),
};

function formatWhen(date: Date): string {
  const ms = Date.now() - date.getTime();
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days} d ago`;
  return date.toISOString().slice(0, 10);
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Label prefers the session title; ids fall back to the timestamp display. */
function sessionLabel(entry: SessionEntry): string {
  const marker = entry.current ? "* " : "  ";
  if (entry.title !== undefined && entry.title.length > 0) {
    return `${marker}${entry.title}`;
  }
  // Display-only: drop the 8-hex uniqueness suffix (`_2c30a4ff`); the id
  // itself and all logic keep the full value.
  const label = entry.id.replace("T", " ").replace(/_[0-9a-f]{8}$/, "");
  return `${marker}${label}`;
}

/**
 * One row's text: the folder is part of the label in the `all` scope so rows
 * from different projects stay distinguishable at a glance, and a legacy
 * foreign row says outright why it cannot be resumed here.
 */
export function describeSessionEntry(
  entry: SessionEntry,
  scope: SessionsScope,
): { label: string; description: string } {
  // In the mixed "All" list every row says which project it belongs to; the
  // current-folder scope is one project by definition, so it stays bare.
  const showFolder = scope === "all";
  const folderName = showFolder ? sessionFolderName(entry) : undefined;
  const folderPath = showFolder ? sessionFolderLabel(entry) : undefined;
  const facts: string[] = [];
  // The label carries the short folder name; the full path (the value the
  // resume actually uses) rides the description.
  if (folderPath !== undefined) facts.push(folderPath);
  facts.push(formatWhen(entry.modifiedAt), formatSize(entry.sizeBytes));
  if (entry.current) facts.push("current");
  if (!isResumableHere(entry)) {
    facts.push("no folder recorded — cannot resume from here");
  }
  return {
    label: sessionLabel(entry) + (folderName === undefined ? "" : `  ·  ${folderName}`),
    description: facts.join(" · "),
  };
}

class SessionsPanel implements Component {
  private readonly title: Text;
  private list?: SelectList;
  private readonly empty: Text;
  private readonly footer: Text;
  private scope: SessionsScope;

  constructor(
    private readonly entries: readonly SessionEntry[],
    initialScope: SessionsScope,
    private readonly choose: (entry: SessionEntry) => void,
    private readonly close: () => void,
    private readonly requestRender: () => void,
  ) {
    this.scope = initialScope;
    this.title = new Text(this.titleLine(), 1, 0);
    this.footer = new Text(
      theme.muted("tab folder scope · ↑↓ browse · enter resume · esc close · history stays on disk"),
      1,
      0,
    );
    this.empty = new Text(this.emptyLine(), 1, 1);
    this.buildList();
  }

  /** `Current Folder | All` with the active scope highlighted. */
  private titleLine(): string {
    const tab = (label: string, active: boolean): string =>
      active ? theme.accent(`[${label}]`) : theme.muted(` ${label} `);
    return (
      theme.brandBold("Sessions") +
      "  " +
      tab("Current Folder", this.scope === "current") +
      theme.muted("|") +
      tab("All", this.scope === "all") +
      theme.muted("  — enter resumes, newest first")
    );
  }

  private emptyLine(): string {
    return theme.muted(
      this.scope === "current"
        ? "No sessions found in this project"
        : "No sessions found in any project",
    );
  }

  private buildList(): void {
    const visible = sessionsForScope(this.entries, this.scope);
    if (visible.length === 0) {
      this.list = undefined;
      return;
    }
    // Values are row indexes, not ids: the same id can legitimately exist in
    // two projects' buckets, and the picker must resume the row the user saw.
    const items: SelectItem[] = visible.map((entry, index) => ({
      value: String(index),
      ...describeSessionEntry(entry, this.scope),
    }));
    const list = new SelectList(items, Math.min(visible.length, 12), selectTheme, {
      minPrimaryColumnWidth: 40,
      maxPrimaryColumnWidth: 64,
    });
    list.onSelect = (item) => {
      const entry = visible[Number(item.value)];
      this.close();
      if (entry !== undefined) this.choose(entry);
    };
    list.onCancel = () => this.close();
    this.list = list;
  }

  private setScope(scope: SessionsScope): void {
    if (scope === this.scope) return;
    this.scope = scope;
    this.title.setText(this.titleLine());
    this.empty.setText(this.emptyLine());
    this.list = undefined;
    this.buildList();
    this.requestRender();
  }

  render(width: number): string[] {
    return [
      ...this.title.render(width),
      ...(this.list === undefined ? this.empty.render(width) : this.list.render(width)),
      ...this.footer.render(width),
    ];
  }

  handleInput(data: string): void {
    // 'q' mirrors the esc dismissal for vi muscle memory; tab swaps the
    // folder scope; everything else (arrows/enter/esc) is SelectList
    // navigation. The list is vertical, so only the up/down arrows move the
    // selection.
    if (matchesKey(data, "q")) {
      this.close();
      return;
    }
    if (matchesKey(data, "tab") || matchesKey(data, "shift+tab")) {
      this.setScope(this.scope === "current" ? "all" : "current");
      return;
    }
    // An empty scope has nothing to navigate: any other key dismisses.
    if (this.list === undefined) {
      this.close();
      return;
    }
    this.list.handleInput(data);
  }

  invalidate(): void {
    this.title.invalidate();
    this.list?.invalidate();
    this.empty.invalidate();
    this.footer.invalidate();
  }
}

/** A focused pi-tui overlay that returns one session to resume. */
export class SessionsOverlay {
  private handle?: OverlayHandle;
  private panel?: SessionsPanel;

  constructor(private readonly tui: SessionsTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(
    entries: readonly SessionEntry[],
    choose: (entry: SessionEntry) => void,
    onClose: () => void,
    options?: { scope?: SessionsScope },
  ): void {
    if (this.handle !== undefined) {
      throw new Error("sessions overlay is already open");
    }
    let settled = false;
    const close = () => {
      if (settled) return;
      settled = true;
      this.hide();
      onClose();
    };
    const panel = new SessionsPanel(
      entries,
      options?.scope ?? "current",
      choose,
      close,
      () => this.tui.requestRender(),
    );
    this.panel = panel;
    this.handle = this.tui.showOverlay(panel, {
      width: "76%",
      maxHeight: "70%",
      anchor: "center",
      margin: 1,
    });
    this.tui.requestRender();
  }

  hide(): void {
    const handle = this.handle;
    this.handle = undefined;
    this.panel = undefined;
    handle?.hide();
    this.tui.requestRender();
  }
}
