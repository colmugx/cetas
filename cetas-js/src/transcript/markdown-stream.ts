/**
 * Incremental pi-tui Markdown for streamed assistant answers.
 *
 * Freeze only complete top-level prose paragraphs. pi-tui still renders every
 * chunk; a suffix that can't be split safely is passed to it whole. In
 * particular, all reference links and definitions stay in the same suffix.
 */
import { Markdown, type Component, type MarkdownTheme } from "@earendil-works/pi-tui";

const MIN_PREFIX = 512;
const BLANK_LINE = /^[ \t]*$/;
const BLOCK_START = /^(?:\s|[#+:-]|\d+[.)](?:\s|$)|=+ *$)/;
const UNCERTAIN = /[\x00-\x1f\x60\[\]_*~$<>|\\\u2028\u2029]/;

/** Return the first character after the last safe blank-line separator. */
export function stableMarkdownCut(text: string): number {
  if (text.length < MIN_PREFIX) return 0;
  let latest = 0;
  let afterBlank = false;
  for (let start = 0; start < text.length;) {
    const newline = text.indexOf("\n", start);
    const line = text.slice(start, newline === -1 ? text.length : newline);
    if (BLANK_LINE.test(line)) {
      if (start === 0) break;
      afterBlank = true;
    } else {
      // Marked emits a separate space token after plain prose. Keep the whole
      // separator in the prefix, but don't cut at a trailing blank line (it
      // can still grow) or before indentation (space can consume it).
      if (afterBlank && start >= MIN_PREFIX && !/^\s/.test(line)) latest = start;
      // Don't try to resume beyond an uncertain block: markup such as raw
      // HTML, display math, and nested lists can consume later blank lines.
      if (BLOCK_START.test(line) || UNCERTAIN.test(line)) break;
      afterBlank = false;
    }
    if (newline === -1) break;
    start = newline + 1;
  }
  return latest;
}

export class IncrementalMarkdown implements Component {
  private text = "";
  private frozenChars = 0;
  private frozen: Markdown[] = [];
  private tail?: Markdown;
  private prefixCache?: { width: number; lines: string[] };

  constructor(initial: string, private readonly x: number, private readonly y: number,
    private readonly theme: MarkdownTheme) {
    this.setText(initial);
  }

  setText(value: string): void {
    if (value === this.text) return;
    if (!value.startsWith(this.text)) {
      this.frozen = [];
      this.frozenChars = 0;
      this.prefixCache = undefined;
    }
    this.text = value;
    const suffix = value.slice(this.frozenChars);
    // Nonzero vertical padding belongs to the whole message, not each chunk.
    const cut = this.y === 0 ? stableMarkdownCut(suffix) : 0;
    if (cut !== 0) {
      this.frozen.push(new Markdown(suffix.slice(0, cut), this.x, this.y, this.theme));
      this.frozenChars += cut;
      this.prefixCache = undefined;
    }
    this.tail?.setText(suffix.slice(cut));
  }

  private renderPrefix(width: number): string[] {
    if (this.prefixCache?.width === width) return this.prefixCache.lines;
    const result: string[] = [];
    for (const block of this.frozen) {
      for (const line of block.render(width)) result.push(line);
    }
    this.prefixCache = { width, lines: result };
    return result;
  }

  render(width: number): string[] {
    // With no safe prefix, the same lazy tail renders the complete message.
    this.tail ??= new Markdown(this.text.slice(this.frozenChars), this.x, this.y, this.theme);
    if (this.frozen.length === 0) return this.tail.render(width);
    return this.renderPrefix(width).concat(this.tail.render(width));
  }

  invalidate(): void {
    this.prefixCache = undefined;
    this.tail?.invalidate();
    for (const block of this.frozen) block.invalidate();
  }
}
