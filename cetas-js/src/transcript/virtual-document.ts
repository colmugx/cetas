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
import { Container, ScrollView, TuiAltScreen, type Component } from "@earendil-works/pi-tui";
import { TranscriptHeightIndex } from "./model.ts";

const LAYOUT_NODE = Symbol.for("@earendil-works/pi-tui/layout-node");
const empty: Component = { render: () => [], invalidate: () => {} };

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
  private readonly windowComponent: Component;
  private width = -1;
  private lastCount = 0;
  private first = 0;
  private end = 0;
  private startRow = 0;
  private lastLines: string[] = [];
  private slots: StackSlot[] = [];
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

  /** A session switch is a new document, even if it has an identical count. */
  reset(): void {
    this.heights.replace([], -1);
    this.lastCount = 0;
    this.width = -1;
    this.first = this.end = this.startRow = 0;
    this.lastLines = [];
    this.slots = [];
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
    this.reconcile(safeWidth);
    const viewport = Math.max(1, Math.floor(this.getViewport()));
    const scrolled = this.getScroll();
    const top = scrolled.followEnd
      ? Math.max(0, this.heights.totalRows - viewport)
      : Math.max(0, Math.floor(scrolled.top));
    const range = this.heights.range(top, viewport, this.overscanRows);
    const lines: string[] = [];
    // Index resolution is O(log N); only visible+overscan components render.
    for (let i = range.first; i < range.endExclusive; i++) {
      const rendered = this.source.children[i]!.render(safeWidth);
      // Blank blocks still occupy a logical row; never let index heights be 0.
      const height = Math.max(1, rendered.length);
      if (height !== this.heights.heightAt(i)) this.heights.update(i, height);
      if (rendered.length === 0) lines.push("");
      else lines.push(...rendered);
    }
    this.first = range.first;
    this.end = range.endExclusive;
    this.lastLines = lines;
    this.startRow = this.heights.prefix(this.first);
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
  view = new ScrollView(document, { follow: "end", primary: true, scrollbar: "auto" });
  return { view, document };
}
