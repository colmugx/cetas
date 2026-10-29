/**
 * Gate 2: windowed pi-tui virtual scroll document.
 *
 * The upstream ScrollView scroll-layout path obtains childBox.rect.height for
 * its logical content height, but also asks the child to render() for search.
 * A three-node VStack reports logical height via numeric basis spacers; its
 * render() is intentionally window-only. Thus no O(history) string arrays are
 * fabricated and pi-tui only paints currently mounted content.
 *
 * This is a pi-tui 1.3-specific adapter. Upstream search/selection are NOT
 * complete across unmounted history; Gate 5 supplies indexed equivalents.
 */
import { Container, ScrollView, TuiAltScreen, sliceByColumn, stripTerminalSequences, visibleWidth, type Component, type TuiMouseEvent, type TuiMouseEventResult } from "@earendil-works/pi-tui";
import { TranscriptSearchIndex, isSearchableComponent, transcriptTextRange } from "./search-index.ts";
import { TranscriptHeightIndex } from "./model.ts";

const LAYOUT_NODE = Symbol.for("@earendil-works/pi-tui/layout-node");
const empty: Component = { render: () => [], invalidate: () => {} };

type PointerPoint = { row: number; col: number };
type StackSlot = { component: Component; basis: number; shrink: number };
type StackNode = {
  type: "vstack";
  entries: readonly StackSlot[];
  gap: number;
  align: "stretch";
};

export interface VirtualDocumentStats {
  readonly totalItems: number;
  readonly logicalRows: number;
  readonly mountedItems: number;
  readonly firstIndex: number;
  readonly endExclusive: number;
  readonly renderedLines: number;
}

/**
 * Accepts legacy components as an interim producer. Gate 3's replay adapter
 * creates them lazily; live ToolRow/Markdown components can remain mutable.
 * All historical component render() calls are outside the hot path.
 */
export class VirtualTranscriptDocument implements Component {
  private readonly heights = new TranscriptHeightIndex();
  private pointerAnchor?: PointerPoint;
  private pointerFocus?: PointerPoint;
  private onCopy?: (text: string) => void | Promise<void>;

  attachCopy(copy: (text: string) => void | Promise<void>): void { this.onCopy = copy; }

  /** Character selection within one message; source-indexed across unmounted messages. */
  getSelectedSourceText(): string | undefined {
    const bounds = this.selectionBounds();
    if (!bounds) return undefined;
    const { start, end } = bounds;
    const first = this.heights.rowToIndex(start.row);
    const last = this.heights.rowToIndex(end.row);
    if (first !== last) {
      // Unmounted history must not be rendered just to copy a long drag.
      try { return transcriptTextRange(this.source.children, first, last) || undefined; }
      catch { return undefined; }
    }

    // Within a message, copy the selected characters rather than the whole
    // message. Terminal columns are cells, not JS string or ANSI offsets.
    const rendered = this.source.children[first]?.render(Math.max(1, this.width < 0 ? this.getWidth() : this.width)) ?? [];
    const baseRow = this.heights.prefix(first);
    const parts: string[] = [];
    for (let row = start.row; row <= end.row; row++) {
      const line = rendered[row - baseRow] ?? "";
      const from = row === start.row ? start.col : 0;
      const to = row === end.row ? end.col + 1 : visibleWidth(line);
      parts.push(stripTerminalSequences(sliceByColumn(line, from, Math.max(0, to - from), true)).trimEnd());
    }
    return parts.join("\n") || undefined;
  }

  private selectionBounds(): { start: PointerPoint; end: PointerPoint } | undefined {
    const anchor = this.pointerAnchor;
    const focus = this.pointerFocus;
    if (!anchor || !focus || (anchor.row === focus.row && anchor.col === focus.col)) return undefined;
    const anchorFirst = anchor.row < focus.row || (anchor.row === focus.row && anchor.col < focus.col);
    return anchorFirst ? { start: anchor, end: focus } : { start: focus, end: anchor };
  }

  /** Only paint the mounted window; native pi-tui selection has no virtual source rows. */
  private paintPointerSelection(line: string, row: number): string {
    const bounds = this.selectionBounds();
    if (!bounds || line.includes("\x1b_G") || line.includes("\x1b]1337;File=")) return line;
    const first = this.heights.rowToIndex(bounds.start.row);
    const last = this.heights.rowToIndex(bounds.end.row);
    const current = this.heights.rowToIndex(row);
    if (current < first || current > last) return line;

    // Cross-message drags select whole blocks, matching the source-indexed
    // clipboard text (including blocks that aren't mounted).
    let from = 0;
    let to = visibleWidth(line);
    if (first === last) {
      if (row < bounds.start.row || row > bounds.end.row) return line;
      if (row === bounds.start.row) from = bounds.start.col;
      if (row === bounds.end.row) to = Math.min(to, bounds.end.col + 1);
    }
    if (to <= from) return line;
    const before = sliceByColumn(line, 0, from, true);
    const middle = sliceByColumn(line, from, to - from, true);
    const after = sliceByColumn(line, to, Math.max(0, visibleWidth(line) - to), true);
    // Reapply inversion after ANSI resets in colored Markdown content.
    const inverted = middle.replace(/\x1b\[[0-?]*[ -/]*m/g, code => code + "\x1b[7m");
    return before + "\x1b[7m" + inverted + "\x1b[27m" + after;
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    // SGR release often carries button=none (code 3), even after a left press.
    if (this.heights.size === 0 ||
        (event.button !== "left" && !(event.type === "release" && event.button === "none"))) return undefined;
    const point: PointerPoint = {
      row: Math.max(0, Math.min(this.heights.totalRows - 1, Math.floor(event.y))),
      col: Math.max(0, Math.min(Math.max(1, this.width < 0 ? this.getWidth() : this.width) - 1, Math.floor(event.x))),
    };
    if (event.type === "press") {
      this.pointerAnchor = point;
      this.pointerFocus = point;
      return { handled: true, capture: true, render: false };
    }
    if (!this.pointerAnchor) return undefined;
    if (event.type === "drag") {
      this.pointerFocus = point;
      return { handled: true, render: true };
    }
    if (event.type === "release") {
      this.pointerFocus = point;
      const text = this.getSelectedSourceText();
      this.pointerAnchor = this.pointerFocus = undefined;
      if (text) void this.onCopy?.(text);
      // Release must repaint: no persistent inverse-video highlight or
      // click-only selection, irrespective of clipboard success.
      return { handled: true, render: true };
    }
    return undefined;
  }
  private readonly windowComponent: Component;
  private width = -1;
  private lastCount = 0;
  private first = 0;
  private end = 0;
  private startRow = 0;
  private lastLines: string[] = [];
  private slots: StackSlot[] = [];
  private searchIndex?: TranscriptSearchIndex;
  private selectedHit = -1;
  setSearchHighlight(index: TranscriptSearchIndex, selectedHit: number): void {
    this.searchIndex = index;
    this.selectedHit = selectedHit;
  }
  clearSearchHighlight(): void { this.searchIndex = undefined; this.selectedHit = -1; }
  private readonly estimateHeight = 3;
  private readonly overscanRows = 10;
  private lastStats: VirtualDocumentStats = {
    totalItems: 0, logicalRows: 0, mountedItems: 0,
    firstIndex: 0, endExclusive: 0, renderedLines: 0,
  };

  constructor(
    private readonly source: Container,
    private readonly getWidth: () => number,
    private readonly getViewport: () => number,
    private readonly getScroll: () => { top: number; followEnd: boolean },
  ) {
    this.windowComponent = { render: () => this.lastLines, invalidate: () => {} };
  }

  get stats(): VirtualDocumentStats { return this.lastStats; }

  private navigate?: (row: number) => void;
  scrollToItem(index: number): void {
    if (index < 0 || index >= this.heights.size) return;
    this.navigate?.(this.heights.prefix(index));
  }
  attachNavigation(scrollTo: (row: number) => void): void { this.navigate = scrollTo; }

  /** A session switch is a new document, even if it has an identical count. */
  reset(): void {
    this.heights.replace([], -1);
    this.lastCount = 0;
    this.width = -1;
    this.first = this.end = this.startRow = 0;
    this.lastLines = [];
    this.slots = [];
    this.pointerAnchor = this.pointerFocus = undefined;
    this.clearSearchHighlight();
  }

  /** Prefer direct append notifications in production; check is O(1) per frame. */
  private reconcile(width: number): void {
    const count = this.source.children.length;
    if (this.width !== width || count < this.lastCount) {
      this.heights.replace(new Array(count).fill(this.estimateHeight), width);
      this.width = width;
    } else {
      for (let i = this.lastCount; i < count; i++) this.heights.append(this.estimateHeight);
    }
    this.lastCount = count;
  }

  private prepare(width: number): void {
    const safeWidth = Math.max(1, Math.floor(width));
    const previousScroll = this.getScroll();
    const widthChanged = this.width !== -1 && this.width !== safeWidth;
    const previousIndex = !previousScroll.followEnd && widthChanged
      ? this.heights.rowToIndex(Math.max(0, previousScroll.top)) : -1;
    const previousOffset = previousIndex >= 0 && previousIndex < this.heights.size
      ? previousScroll.top - this.heights.prefix(previousIndex) : 0;
    this.reconcile(safeWidth);
    if (previousIndex >= 0 && previousIndex < this.heights.size) {
      const correctedTop = this.heights.prefix(previousIndex) +
        Math.min(previousOffset, this.heights.heightAt(previousIndex) - 1);
      if (correctedTop !== previousScroll.top) this.navigate?.(correctedTop);
    }
    const viewport = Math.max(1, Math.floor(this.getViewport()));
    const scrolled = this.getScroll();
    const top = scrolled.followEnd
      ? Math.max(0, this.heights.totalRows - viewport)
      : Math.max(0, Math.floor(scrolled.top));
    // Preserve the topmost visible message and its intra-message line when
    // measured component heights differ from estimates. Only adjust when
    // follow-end is disabled; the ScrollView owns end-following otherwise.
    const anchorIndex = !scrolled.followEnd ? this.heights.rowToIndex(top) : -1;
    const anchorOffset = anchorIndex >= 0 && anchorIndex < this.heights.size
      ? top - this.heights.prefix(anchorIndex) : 0;
    const range = this.heights.range(top, viewport, this.overscanRows);
    const lines: string[] = [];
    // Index resolution is O(log N); only visible+overscan components render.
    for (let i = range.first; i < range.endExclusive; i++) {
      const component = this.source.children[i]!;
      const rendered = component.render(safeWidth);
      // Highlight only literal source matches that can be located exactly on
      // rendered rows. Markdown transformations are intentionally not guessed.
      const hits = this.searchIndex?.hitsAt(i);
      const highlighted = hits !== undefined && hits.length > 0 && isSearchableComponent(component)
        ? highlightLiteralRows(rendered, component.getSearchText(), hits.map(hit => ({ offset: hit.offset, length: hit.length })), safeWidth)
        : rendered;
      // Blank blocks still occupy a logical row; never let index heights be 0.
      const height = Math.max(1, rendered.length);
      if (height !== this.heights.heightAt(i)) this.heights.update(i, height);
      if (highlighted.length === 0) lines.push("");
      else lines.push(...highlighted);
    }
    if (anchorIndex >= 0 && anchorIndex < this.heights.size) {
      const corrected = this.heights.prefix(anchorIndex) +
        Math.min(anchorOffset, this.heights.heightAt(anchorIndex) - 1);
      if (corrected !== top && this.navigate) this.navigate(corrected);
    }
    this.first = range.first;
    this.end = range.endExclusive;
    this.startRow = this.heights.prefix(this.first);
    this.lastLines = lines.map((line, row) => this.paintPointerSelection(line, this.startRow + row));
    const bottomRows = Math.max(0, this.heights.totalRows - this.startRow - lines.length);
    this.slots = [
      { component: empty, basis: this.startRow, shrink: 0 },
      { component: this.windowComponent, basis: lines.length, shrink: 0 },
      { component: empty, basis: bottomRows, shrink: 0 },
    ];
    this.lastStats = {
      totalItems: this.lastCount,
      logicalRows: this.heights.totalRows,
      mountedItems: this.end - this.first,
      firstIndex: this.first,
      endExclusive: this.end,
      renderedLines: lines.length,
    };
  }

  /** Called by pi-tui's layout engine before it sizes the scroll child. */
  [LAYOUT_NODE](): StackNode {
    this.prepare(this.getWidth());
    return { type: "vstack", entries: this.slots, gap: 0, align: "stretch" };
  }

  /** Render cache for search/overlays: intentionally the *visible slice*. */
  render(_width: number): string[] { return this.lastLines; }
  invalidate(): void { /* Components refresh themselves on each visible frame. */ }
}

/**
 * Consumes left-button interaction at the SCROLL VIEW hit target.
 *
 * Native pi-tui selection reads a full-document line array, but the virtual
 * transcript intentionally only paints mounted rows. Forward events into its
 * own character selection and source-indexed cross-message copy instead.
 *
 * Wheel, scrollbar and non-left-button input remain pi-tui-owned.
 */
export class TranscriptScrollView extends ScrollView {
  constructor(private readonly transcriptDocument: VirtualTranscriptDocument) {
    super(transcriptDocument, { follow: "end", primary: true, scrollbar: "auto" });
  }

  override handleMouse(event: TuiMouseEvent): ReturnType<ScrollView["handleMouse"]> {
    if (event.button !== "left" && !(event.type === "release" && event.button === "none")) return undefined;
    if (event.type !== "press" && event.type !== "drag" &&
        event.type !== "release" && event.type !== "click") return undefined;
    // ScrollView is viewport-relative; TranscriptDocument's height index is
    // document-relative. This also handles regions not occupied by a child.
    const forwarded = event.type === "click" ? undefined : this.transcriptDocument.handleMouse({
      ...event,
      y: event.y + this.scrollTop,
    });
    // ScrollView inherits Container.handleMouse(), whose return contract
    // includes a concrete target. Target *this* view, not the document:
    // pi-tui uses its origin to retarget subsequent capture drag/releases.
    return {
      ...forwarded,
      // TuiMouseDispatchResult.handled must be literal true. The forwarded
      // component result has handled?: boolean; spread it BEFORE this flag.
      handled: true,
      ...(event.type === "press" ? { capture: true } : {}),
      render: forwarded?.render ?? false,
      target: {
        component: this,
        originX: event.screenX - event.x,
        originY: event.screenY - event.y,
        width: event.width,
        height: event.height,
      },
    };
  }
}

/** Exact window height and pinning state live in pi-tui ScrollView. */
export function createVirtualScroll(
  source: Container,
  tui: TuiAltScreen,
  getViewport: () => number,
): { view: ScrollView; document: VirtualTranscriptDocument } {
  let view: ScrollView | undefined;
  const document = new VirtualTranscriptDocument(
    source,
    () => tui.terminal.columns,
    getViewport,
    () => ({ top: view?.scrollTop ?? 0, followEnd: view?.isFollowingEnd ?? true }),
  );
  view = new TranscriptScrollView(document);
  document.attachNavigation((row) => view!.scrollTo(row, { disableFollow: true }));
  return { view: view!, document };
}

/** Exact literal-row matches only; preserves the existing ANSI escapes. */
export function highlightLiteralRows(
  rows: readonly string[], source: string,
  hits: readonly { offset: number; length: number }[], width: number,
): string[] {
  if (!hits.length || !source) return [...rows];
  // Markdown may change source text into formatted terminal content. Only
  // highlight when the source line occurs literally within a rendered row.
  const sourceLines = source.split("\n");
  return rows.map(raw => {
    if (raw.includes("\x1b_G") || raw.includes("\x1b]1337;File=")) return raw;
    const plain = raw.replace(/\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "");
    const ranges: {start:number;end:number}[] = [];
    let startOffset=0;
    for (const line of sourceLines) {
      const displayStart=plain.indexOf(line);
      if (line && displayStart>=0) {
        for (const hit of hits) {
          const localStart=hit.offset-startOffset;
          if (localStart>=0 && localStart+hit.length<=line.length) {
            const prefix=plain.slice(0,displayStart+localStart);
            const start=visibleWidth(prefix);
            const len=visibleWidth(line.slice(localStart,localStart+hit.length));
            if(start+len<=width) ranges.push({start,end:start+len});
          }
        }
      }
      startOffset+=line.length+1;
    }
    if (!ranges.length) return raw;
    let result=raw;
    for (const range of ranges.sort((a,b)=>b.start-a.start)) {
      const before=sliceByColumn(result,0,range.start,true);
      const middle=sliceByColumn(result,range.start,range.end-range.start,true);
      const after=sliceByColumn(result,range.end,Math.max(0,visibleWidth(result)-range.end),true);
      result=before+"\x1b[4m"+middle+"\x1b[24m"+after;
    }
    return result;
  });
}
