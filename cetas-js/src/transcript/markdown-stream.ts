/**
 * Incremental pi-tui Markdown for streamed assistant answers.
 *
 * Complete paragraphs separated by a blank line are frozen only at
 * conservative top-level boundaries. All actual Markdown rendering remains
 * pi-tui's, including ANSI, highlighting, tables, LaTeX and Kitty images.
 *
 * A newly frozen checkpoint and each new width are checked against a full
 * upstream Markdown render. If a seam differs, retain exact upstream output
 * and stop splitting that message. This protects Markdown semantics over
 * speculative performance gains.
 */
import { Markdown, type Component, type MarkdownTheme } from "@earendil-works/pi-tui";

const MIN_PREFIX = 512;
const REF_LINK = /\[[^\]\n]+\]\[[^\]\n]*\]|^ {0,3}\[[^\]\n]+\]:/m;
const BLOCK_START = /^\s*(?:[#>*+-]\s|#{1,6}(?:\s|$)|\d+[.)]\s|\x60{3,}|~{3,}|\$\$|<|\||-{3,}\s*$|_{3,}\s*$)/;
const INLINE_UNCERTAIN = /[\x60\[\]_*~$<>|\\]/;

/** Return the first character after a stable blank-line separator. */
export function stableMarkdownCut(text: string): number {
  if (text.length < MIN_PREFIX || REF_LINK.test(text)) return 0;
  let latest = 0;
  let start = 0;
  let previous = "";
  let fence = "";
  let fenceLength = 0;
  let math = false;
  for (let end = 0; end <= text.length; end++) {
    if (end < text.length && text[end] !== "\n") continue;
    const line = text.slice(start, end);
    const trimmed = line.trim();
    const mark = /^ {0,3}(\x60{3,}|~{3,})/.exec(line)?.[1];
    if (mark !== undefined) {
      if (!fence) { fence = mark[0]!; fenceLength = mark.length; }
      else if (mark[0] === fence && mark.length >= fenceLength &&
        trimmed === mark) { fence = ""; }
    }
    if (!fence && trimmed === "$$") math = !math;
    if (!fence && !math && trimmed === "" && end >= MIN_PREFIX &&
        end + 1 < text.length && text[end + 1] !== "\n" &&
        previous.trim() !== "" && !BLOCK_START.test(previous) &&
        !INLINE_UNCERTAIN.test(previous)) {
      const nextEnd = text.indexOf("\n", end + 1);
      const next = text.slice(end + 1, nextEnd === -1 ? text.length : nextEnd);
      if (next.trim() && !/^\s/.test(next) && !BLOCK_START.test(next) &&
          !INLINE_UNCERTAIN.test(next)) latest = end + 1;
    }
    if (trimmed) previous = line;
    start = end + 1;
  }
  return latest;
}

export interface IncrementalMarkdownStats {
  frozenBlocks: number;
  frozenCharacters: number;
  tailCharacters: number;
  prefixRenders: number;
  tailRenders: number;
  parityChecks: number;
  fallback: boolean;
}

export class IncrementalMarkdown implements Component {
  private text = "";
  private frozenChars = 0;
  private frozen: Markdown[] = [];
  private tail: Markdown;
  private reference: Markdown;
  private prefixCache?: { width: number; blocks: number; lines: string[] };
  private failed = false;
  private validate = false;
  private checkedWidth?: number;
  private prefixRenders = 0;
  private tailRenders = 0;
  private parityChecks = 0;

  constructor(initial: string, private readonly x: number, private readonly y: number,
    private readonly theme: MarkdownTheme) {
    this.reference = new Markdown(initial, x, y, theme);
    this.tail = new Markdown("", x, y, theme);
    this.setText(initial);
  }

  setText(value: string): void {
    if (value === this.text) return;
    if (!value.startsWith(this.text) || REF_LINK.test(value.slice(this.frozenChars))) {
      this.frozen = [];
      this.frozenChars = 0;
      this.prefixCache = undefined;
      this.checkedWidth = undefined;
      // Global Markdown reference syntax can retroactively modify old blocks.
      this.failed = REF_LINK.test(value);
      this.validate = false;
    }
    this.text = value;
    this.reference.setText(value);
    if (!this.failed) {
      let suffix = value.slice(this.frozenChars);
      for (let i = 0; i < 16; i++) {
        const cut = stableMarkdownCut(suffix);
        if (cut === 0) break;
        const chunk = suffix.slice(0, cut - 2);
        if (!chunk.trim()) break;
        this.frozen.push(new Markdown(chunk, this.x, this.y, this.theme));
        this.frozenChars += cut;
        suffix = value.slice(this.frozenChars);
        this.prefixCache = undefined;
        this.validate = true;
        this.checkedWidth = undefined;
      }
    }
    this.tail.setText(value.slice(this.frozenChars));
  }

  private renderPrefix(width: number): string[] {
    if (this.prefixCache?.width === width && this.prefixCache.blocks === this.frozen.length)
      return this.prefixCache.lines;
    const result: string[] = [];
    for (const block of this.frozen) {
      result.push(...block.render(width), " ".repeat(Math.max(0, width)));
    }
    this.prefixRenders++;
    this.prefixCache = { width, blocks: this.frozen.length, lines: result };
    return result;
  }

  render(width: number): string[] {
    if (this.failed || this.frozen.length === 0) return this.reference.render(width);
    const prefix = this.renderPrefix(width);
    this.tailRenders++;
    const result = prefix.concat(this.tail.render(width));
    if (this.validate || this.checkedWidth !== width) {
      this.parityChecks++;
      const exact = this.reference.render(width);
      if (exact.length !== result.length || exact.some((line, i) => line !== result[i])) {
        this.failed = true;
        this.frozen = [];
        this.frozenChars = 0;
        this.prefixCache = undefined;
        this.tail.setText(this.text);
        return exact;
      }
      this.checkedWidth = width;
      this.validate = false;
    }
    return result;
  }

  invalidate(): void {
    this.prefixCache = undefined;
    this.checkedWidth = undefined;
    this.tail.invalidate();
    this.reference.invalidate();
    for (const block of this.frozen) block.invalidate();
  }

  get stats(): IncrementalMarkdownStats {
    return {
      frozenBlocks: this.frozen.length,
      frozenCharacters: this.frozenChars,
      tailCharacters: this.text.length - this.frozenChars,
      prefixRenders: this.prefixRenders,
      tailRenders: this.tailRenders,
      parityChecks: this.parityChecks,
      fallback: this.failed,
    };
  }
}
