/**
 * Session browser UI for cetas-js.
 *
 * Lists the JSONL transcript files under the project sessions directory and
 * returns the chosen session id — the host then repoints the application at
 * it (`setSession`). The overlay reads nothing from the files beyond stat
 * metadata; replaying history into the transcript is out of scope (the
 * session store already feeds the model its context on the next turn).
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
  /** True for the session the application currently writes to. */
  current: boolean;
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

/** Session ids embed the UTC timestamp (`2026-08-26T19-02-…`); surface it. */
function sessionLabel(entry: SessionEntry): string {
  const marker = entry.current ? "* " : "  ";
  // Display-only: drop the 8-hex uniqueness suffix (`_2c30a4ff`); the id
  // itself and all logic keep the full value.
  const label = entry.id.replace("T", " ").replace(/_[0-9a-f]{8}$/, "");
  return `${marker}${label}`;
}

class SessionsPanel implements Component {
  private readonly title: Text;
  private readonly list?: SelectList;
  private readonly empty: Text;
  private readonly footer: Text;

  constructor(
    entries: readonly SessionEntry[],
    private readonly choose: (id: string) => void,
    private readonly close: () => void,
  ) {
    this.title = new Text(
      theme.brandBold("Sessions") + theme.muted("  — enter resumes, newest first"),
      1,
      0,
    );
    if (entries.length === 0) {
      this.list = undefined;
      this.empty = new Text(theme.muted("No sessions found in this project"), 1, 1);
    } else {
      const items: SelectItem[] = entries.map((entry) => ({
        value: entry.id,
        label: sessionLabel(entry),
        description: `${formatWhen(entry.modifiedAt)} · ${formatSize(entry.sizeBytes)}${entry.current ? " · current" : ""}`,
      }));
      this.list = new SelectList(items, Math.min(entries.length, 12), selectTheme, {
        minPrimaryColumnWidth: 40,
        maxPrimaryColumnWidth: 64,
      });
      this.list.onSelect = (item) => {
        this.close();
        this.choose(item.value);
      };
      this.list.onCancel = () => this.close();
      this.empty = new Text("", 0, 0);
    }
    this.footer = new Text(
      theme.muted("↑↓ browse · enter resume · esc close · history stays on disk"),
      1,
      0,
    );
  }

  render(width: number): string[] {
    return [
      ...this.title.render(width),
      ...(this.list === undefined ? this.empty.render(width) : this.list.render(width)),
      ...this.footer.render(width),
    ];
  }

  handleInput(data: string): void {
    // 'q' mirrors the esc dismissal for vi muscle memory; everything else
    // (up/down/enter/esc) is SelectList navigation.
    if (this.list === undefined || matchesKey(data, "q")) {
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

/** A focused pi-tui overlay that returns one session id to resume. */
export class SessionsOverlay {
  private handle?: OverlayHandle;
  private panel?: SessionsPanel;

  constructor(private readonly tui: SessionsTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(
    entries: readonly SessionEntry[],
    choose: (id: string) => void,
    onClose: () => void,
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
    const panel = new SessionsPanel(entries, choose, close);
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
