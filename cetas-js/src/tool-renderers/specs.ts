/**
 * specs.ts — declarative ToolRow spec table.
 *
 * Rendering knowledge lives here as data: how to pull the primary/secondary
 * argument segments off a tool call, and how to summarize its result. The
 * generic engine in registry.ts turns a spec into a ToolRenderer; unknown
 * tools fall back to the JSON-dump renderer.
 *
 * This module must not import from registry.ts (the engine imports this
 * table), so tiny helpers are duplicated locally instead of shared.
 */

import { theme } from "../../ui/theme.ts";

export interface ArgSpec {
  /** Candidate argument keys — first hit wins, e.g. ["cmd","command"]. */
  keys: string[];
  /** Value → display text (already styled when needed, e.g. theme.yellow). */
  render?: (v: string, args: unknown) => string;
  /** Used when no key hits. Omit to drop the segment entirely. */
  fallback?: string;
}

export interface ToolRowSpec {
  /** Defaults to the wire tool name. */
  title?: string;
  primary: ArgSpec[];
  secondary?: ArgSpec[];
  /**
   * Second-line summary. May return multiple "\n"-joined physical lines
   * (glob appends a file-preview line). Undefined lets the engine fall
   * back to structured.summary, then to truncated content.
   */
  summarize?: (r: { content: string; structured?: unknown }) => string | undefined;
}

/** Extract the reserved `summary : String` field from a structured payload. */
export function summaryOf(structured: unknown): string | undefined {
  if (
    structured !== null &&
    typeof structured === "object" &&
    !Array.isArray(structured)
  ) {
    const s = (structured as Record<string, unknown>).summary;
    if (typeof s === "string" && s.length > 0) return s;
  }
  return undefined;
}

function truncateLine(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

/** Collapse content to one truncated preview line (the engine's last resort). */
function truncatePreview(s: string, max: number): string {
  const oneLine = s.replace(/\n/g, " ");
  return oneLine.length > max ? oneLine.slice(0, max) + "…" : oneLine;
}

/** Count from a `Found N <noun>` header line (ext-grep/ext-glob format). */
function headerCount(content: string, noun: string): number | undefined {
  const m = content.split("\n")[0]?.match(new RegExp(`^Found (\\d+) ${noun}`));
  return m ? Number(m[1]) : undefined;
}

const readSpec: ToolRowSpec = {
  primary: [{ keys: ["path"], fallback: "(no path)" }],
  summarize: ({ content }) => {
    const lines = content.split("\n");
    const firstLine = truncateLine(lines[0] ?? "", 120);
    return lines.length > 1
      ? `${firstLine}  ${theme.muted(`(+${lines.length - 1} lines)`)}`
      : firstLine;
  },
};

const writeSpec: ToolRowSpec = {
  primary: [{ keys: ["path"], fallback: "(no path)" }],
  secondary: [{ keys: ["content"], render: (c) => `(${c.length} bytes)` }],
};

const editSpec: ToolRowSpec = {
  primary: [{ keys: ["path"], fallback: "(no path)" }],
  secondary: [
    {
      keys: ["replace_all"],
      render: (v) => (v === "true" ? "(all)" : "(single)"),
      // ext-edit omits replace_all for single edits; argBool defaulted false.
      fallback: "(single)",
    },
  ],
};

const globSpec: ToolRowSpec = {
  primary: [
    { keys: ["pattern"], fallback: "(no pattern)", render: (v) => theme.yellow(v) },
  ],
  secondary: [{ keys: ["path"], fallback: "." }],
  summarize: ({ content, structured }) => {
    const headerN = headerCount(content, "files");
    const summary =
      summaryOf(structured) ??
      (headerN !== undefined ? `${headerN} file${headerN === 1 ? "" : "s"}` : undefined);
    if (summary === undefined) return undefined;
    const entries = content
      .split("\n")
      .slice(1)
      .filter((l) => l.length > 0);
    if (entries.length === 0) return summary;
    const preview = entries.slice(0, 3).join("  ");
    const more = entries.length > 3 ? ` (+${entries.length - 3} more)` : "";
    return `${summary}\n${preview}${more}`;
  },
};

const grepSpec: ToolRowSpec = {
  primary: [
    { keys: ["pattern"], fallback: "(no pattern)", render: (v) => theme.yellow(v) },
  ],
  secondary: [{ keys: ["path"], fallback: "." }],
  summarize: ({ content, structured }) => {
    const structuredSummary = summaryOf(structured);
    if (structuredSummary !== undefined) return structuredSummary;
    const n = headerCount(content, "matches");
    if (n !== undefined) return `${n} match${n === 1 ? "" : "es"}`;
    if (content.startsWith("No matches found")) return "no matches";
    return truncatePreview(content, 200);
  },
};

export const TOOL_ROW_SPECS: Record<string, ToolRowSpec> = {
  read: readSpec,
  write: writeSpec,
  edit: editSpec,
  glob: globSpec,
  grep: grepSpec,
};
