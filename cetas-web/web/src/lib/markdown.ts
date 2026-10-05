import DOMPurify from "dompurify";
import { Marked } from "marked";
import { createHighlighter, type Highlighter } from "shiki";

// Languages preloaded at startup; unknown fence languages fall back to text.
const PRELOADED_LANGS = [
  "typescript",
  "javascript",
  "json",
  "markdown",
  "bash",
  "python",
  "html",
  "css",
  "diff",
];

let highlighterPromise: Promise<Highlighter> | undefined;

async function getHighlighter(): Promise<Highlighter> {
  highlighterPromise ??= createHighlighter({
    themes: ["github-light", "github-dark"],
    langs: PRELOADED_LANGS,
  });
  return highlighterPromise;
}

export async function highlightCode(
  code: string,
  lang: string,
): Promise<string> {
  const highlighter = await getHighlighter();
  const resolved = highlighter.getLoadedLanguages().includes(lang)
    ? lang
    : "text";
  return highlighter.codeToHtml(code, {
    lang: resolved,
    themes: { light: "github-light", dark: "github-dark" },
  });
}

const markedInstance = new Marked({ gfm: true, breaks: false });
const sanitizer = DOMPurify();

/** Render a closed markdown block (no fences inside) to sanitized HTML. */
export function renderMarkdownBlock(text: string): string {
  return sanitizer.sanitize(markedInstance.parse(text) as string);
}

export function escapeHtml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export type StreamBlock = { key: string; kind: "fence" | "para"; text: string };

/**
 * Split streamed markdown into blocks that will not change as more text
 * arrives (closed fences and closed paragraphs), plus the still-growing tail.
 */
export function splitStream(
  text: string,
): { blocks: StreamBlock[]; tail: string } {
  const lines = text.split("\n");
  const blocks: StreamBlock[] = [];
  let start = 0;
  let index = 0;

  while (index < lines.length) {
    if (lines[index].trimStart().startsWith("```")) {
      const close = findClosingFence(lines, index + 1);
      if (close === -1) break;
      pushBlock(blocks, lines, start, close, "fence");
      index = close + 1;
      start = index;
      continue;
    }
    const blank = lines.indexOf("", index);
    if (blank === -1) break;
    if (blank > start) {
      pushBlock(blocks, lines, start, blank, "para");
    }
    index = blank + 1;
    start = index;
  }

  return { blocks, tail: lines.slice(start).join("\n") };
}

function findClosingFence(lines: string[], from: number): number {
  for (let i = from; i < lines.length; i++) {
    if (lines[i].trimStart().startsWith("```")) return i;
  }
  return -1;
}

function pushBlock(
  blocks: StreamBlock[],
  lines: string[],
  from: number,
  to: number,
  kind: StreamBlock["kind"],
) {
  const text = lines.slice(from, to).join("\n");
  if (text.trim().length === 0) return;
  blocks.push({ key: `${from}:${to}:${kind}:${text.length}`, kind, text });
}

/** Split a fence block into its info string and code body. */
export function parseFence(text: string): { lang: string; code: string } {
  const firstNewline = text.indexOf("\n");
  const info = text
    .slice(0, firstNewline === -1 ? undefined : firstNewline)
    .replace(/[\s`]/g, "");
  const code = firstNewline === -1 ? "" : text.slice(firstNewline + 1);
  return { lang: info || "text", code };
}

/**
 * Synthesize a line-level diff from an edit's old/new text by trimming the
 * common prefix and suffix. Good enough for model-sized edits and instant.
 */
export type DiffLine = { sign: " " | "-" | "+"; text: string };

export function synthesizeDiff(
  oldText: string | undefined,
  newText: string | undefined,
): DiffLine[] {
  const before = (oldText ?? "").split("\n");
  const after = (newText ?? "").split("\n");
  let prefix = 0;
  while (
    prefix < before.length &&
    prefix < after.length &&
    before[prefix] === after[prefix]
  ) {
    prefix++;
  }
  let suffix = 0;
  while (
    suffix < before.length - prefix &&
    suffix < after.length - prefix &&
    before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
  ) {
    suffix++;
  }
  const removed = before.slice(prefix, before.length - suffix);
  const added = after.slice(prefix, after.length - suffix);
  const contextBefore = before.slice(Math.max(0, prefix - 3), prefix);
  const contextAfter = before.slice(
    before.length - suffix,
    before.length - suffix + 3,
  );
  return [
    ...contextBefore.map((line) => ({ sign: " " as const, text: line })),
    ...removed.map((line) => ({ sign: "-" as const, text: line })),
    ...added.map((line) => ({ sign: "+" as const, text: line })),
    ...contextAfter.map((line) => ({ sign: " " as const, text: line })),
  ];
}
