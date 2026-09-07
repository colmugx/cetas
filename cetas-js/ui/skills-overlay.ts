/**
 * Skills browser UI for cetas-js.
 *
 * The overlay only understands the provider-neutral `/skills` command result:
 * skill name / description / discovery scope. It is display-only — activation
 * happens through the `$name` mention path or the model-facing activate_skill
 * tool, never from this picker. Descriptions are discovery-time metadata; the
 * SKILL.md body is not loaded here (progressive disclosure).
 */

import {
  SelectList,
  Text,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";
import { matchesKey } from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";

export type SkillScope = "project" | "user" | "extra";

export interface SkillsEntry {
  name: string;
  description: string;
  scope: SkillScope;
  /** Configured extra root; present only for scope === "extra". */
  root?: string;
}

export interface SkillsTui {
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

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return string(value, path);
}

function scope(value: unknown, path: string): SkillScope {
  const text = string(value, path);
  if (text !== "project" && text !== "user" && text !== "extra") {
    throw new Error(`${path} is not a known skill scope: ${text}`);
  }
  return text;
}

/** Parse a `/skills` CommandOutcome and reject malformed command output. */
export function parseSkillsOutcome(
  raw: string,
):
  | { type: "success"; feedback?: string; entries: SkillsEntry[] }
  | { type: "failure"; reason: string }
  | { type: "needs_input"; prompt: string } {
  const value: unknown = JSON.parse(raw);
  const outcome = record(value, "skills outcome");
  const type = string(outcome.type, "skills outcome.type");
  if (type === "failure") {
    return { type, reason: string(outcome.reason, "skills outcome.reason") };
  }
  if (type === "needs_input") {
    return {
      type,
      prompt: string(outcome.prompt ?? "", "skills outcome.prompt"),
    };
  }
  if (type !== "success") {
    throw new Error(`skills outcome.type is unsupported: ${type}`);
  }
  const structured = record(outcome.structured, "skills outcome.structured");
  if (string(structured.kind, "skills outcome.structured.kind") !== "skills_catalog") {
    throw new Error("skills outcome.structured.kind must be skills_catalog");
  }
  const rawSkills = structured.skills;
  if (!Array.isArray(rawSkills)) {
    throw new Error("skills outcome.structured.skills must be an array");
  }
  const entries = rawSkills.map((rawEntry, index) => {
    const path = `skills outcome.structured.skills[${index}]`;
    const entry = record(rawEntry, path);
    return {
      name: string(entry.name, `${path}.name`),
      description: string(entry.description, `${path}.description`),
      scope: scope(entry.scope, `${path}.scope`),
      root: optionalString(entry.root, `${path}.root`),
    };
  });
  return { type, feedback: optionalString(outcome.feedback, "skills outcome.feedback"), entries };
}

/** Parse a `/skills` activation outcome for the `$name` mention path. */
export function parseSkillActivation(
  raw: string,
):
  | { type: "success"; name: string; instructions: string }
  | { type: "failure"; reason: string } {
  const value: unknown = JSON.parse(raw);
  const outcome = record(value, "skills outcome");
  const type = string(outcome.type, "skills outcome.type");
  if (type === "failure") {
    return { type, reason: string(outcome.reason, "skills outcome.reason") };
  }
  if (type !== "success") {
    throw new Error(`skills outcome.type is unsupported: ${type}`);
  }
  const structured = record(outcome.structured, "skills outcome.structured");
  if (string(structured.kind, "skills outcome.structured.kind") !== "agent_skill_activation") {
    throw new Error("skills outcome.structured.kind must be agent_skill_activation");
  }
  return {
    type,
    name: string(structured.name, "skills outcome.structured.name"),
    instructions: string(structured.instructions, "skills outcome.structured.instructions"),
  };
}

function scopeBadge(entry: SkillsEntry): string {
  switch (entry.scope) {
    case "project":
      return theme.accent("[project]");
    case "user":
      return theme.success("[user]");
    case "extra":
      return theme.info(`[extra${entry.root === undefined ? "" : `:${entry.root}`}]`);
  }
}

class SkillsPanel implements Component {
  private readonly title: Text;
  private readonly list?: SelectList;
  private readonly empty: Text;
  private readonly footer: Text;

  constructor(
    entries: readonly SkillsEntry[],
    private readonly close: () => void,
  ) {
    this.title = new Text(theme.brandBold("Agent Skills") + theme.muted("  — discovery scope per entry"), 1, 0);
    if (entries.length === 0) {
      this.list = undefined;
      this.empty = new Text(theme.muted("No skills discovered"), 1, 1);
    } else {
      const items: SelectItem[] = entries.map((entry) => ({
        value: `$${entry.name}`,
        label: `${scopeBadge(entry)} ${entry.name}`,
        description: entry.description,
      }));
      this.list = new SelectList(items, Math.min(entries.length, 12), selectTheme);
      this.list.onSelect = () => this.close();
      this.list.onCancel = () => this.close();
      this.empty = new Text("", 0, 0);
    }
    this.footer = new Text(theme.muted("↑↓ browse · enter/esc close · display only — activate with $name"), 1, 0);
  }

  render(width: number): string[] {
    const lines = [
      ...this.title.render(width),
      ...(this.list === undefined ? this.empty.render(width) : this.list.render(width)),
      ...this.footer.render(width),
    ];
    return lines;
  }

  handleInput(data: string): void {
    // 'q' mirrors the esc dismissal for vi muscle memory; everything else
    // (arrows/enter/esc) is SelectList navigation. The list is vertical, so
    // only the up/down arrows move the selection.
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

/** A focused, display-only pi-tui overlay listing discovered agent skills. */
export class SkillsOverlay {
  private handle?: OverlayHandle;
  private panel?: SkillsPanel;

  constructor(private readonly tui: SkillsTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  open(entries: readonly SkillsEntry[], onClose: () => void): void {
    if (this.handle !== undefined) {
      throw new Error("skills overlay is already open");
    }
    let settled = false;
    const close = () => {
      if (settled) return;
      settled = true;
      this.hide();
      onClose();
    };
    const panel = new SkillsPanel(entries, close);
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
