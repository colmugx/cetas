/**
 * Gate 5: search and copy the transcript source, NOT its mounted pi-tui rows.
 * Search time is O(document characters); render time stays bounded by view.
 * Caches are invalidated by caller's revision epoch, never by viewport paint.
 */
import type { Component } from "@earendil-works/pi-tui";

export interface SearchableComponent extends Component {
  getSearchText(): string;
}
export function isSearchableComponent(component: Component): component is SearchableComponent {
  return typeof (component as Partial<SearchableComponent>).getSearchText === "function";
}
export interface TranscriptSearchHit {
  readonly index: number;
  readonly offset: number;
  readonly length: number;
}
export interface TranscriptSearchStats {
  readonly inspected: number;
  readonly matches: number;
  readonly materialized: number;
}

export class TranscriptSearchIndex {
  private hits: TranscriptSearchHit[] = [];
  private lastQuery = "";
  private statsValue: TranscriptSearchStats = {inspected:0,matches:0,materialized:0};
  get matches(): readonly TranscriptSearchHit[] { return this.hits; }
  get stats(): TranscriptSearchStats { return this.statsValue; }
  get query(): string { return this.lastQuery; }

  /** Search is explicit/on-demand, not part of a TUI layout or redraw. */
  search(components: readonly Component[], query: string, limit = 10000): readonly TranscriptSearchHit[] {
    const needle = query.trim().toLocaleLowerCase();
    this.lastQuery = query.trim();
    this.hits = [];
    let inspected = 0;
    if (needle) {
      outer: for (let index=0; index<components.length; index++) {
        const block = components[index]!;
        if (!isSearchableComponent(block)) continue;
        inspected++;
        const source = block.getSearchText().toLocaleLowerCase();
        for (let start=0; start < source.length;) {
          const at = source.indexOf(needle, start);
          if (at < 0) break;
          this.hits.push({index,offset:at,length:needle.length});
          if (this.hits.length >= limit) break outer;
          start = at + Math.max(1,needle.length);
        }
      }
    }
    this.statsValue = {inspected,matches:this.hits.length,materialized:0};
    return this.hits;
  }

  /** Search-result navigation is stable within one search snapshot. */
  next(current: number, reverse = false): number {
    if (this.hits.length === 0) return -1;
    return (current + (reverse ? this.hits.length-1 : 1)) % this.hits.length;
  }

  clear(): void {
    this.hits = [];
    this.lastQuery = "";
    this.statsValue = {inspected:0,matches:0,materialized:0};
  }
}

/**
 * Copy an inclusive range of transcript blocks without rendering any
 * offscreen Markdown, images or ToolRows. Indices are zero-based.
 * Text is the original message text, not colored/truncated terminal cells.
 */
export function transcriptTextRange(
  components: readonly Component[],
  first: number,
  last: number,
  maxChars = 4_000_000,
): string {
  if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last) ||
      first < 0 || last < first || last >= components.length)
    throw new RangeError("invalid transcript copy range");
  const parts: string[] = [];
  let used = 0;
  for (let i=first;i<=last;i++) {
    const c = components[i]!;
    if (!isSearchableComponent(c)) continue;
    const text = c.getSearchText();
    if (!text) continue;
    const delimiter = used > 0 ? "\n\n" : "";
    if (used + delimiter.length + text.length > maxChars)
      throw new RangeError("selected transcript text exceeds the copy limit");
    parts.push(text);
    used += delimiter.length + text.length;
  }
  return parts.join("\n\n");
}
