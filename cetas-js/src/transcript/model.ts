/**
 * Gate 1: renderer-independent transcript data and height index.
 *
 * The SessionStore/JSONL remains canonical. This in-memory model has stable
 * identities; no TUI components are retained here. A view can mount only the
 * visible ranges selected by TranscriptHeightIndex.
 */
export interface TranscriptBlock<T = unknown> {
  readonly id: string;
  readonly revision: number;
  readonly kind: string;
  readonly value: T;
}
export interface TranscriptAnchor {
  readonly id: string;
  /** Visible offset inside the block, 0-based. */
  readonly localRow: number;
}
export interface TranscriptVisibleRange {
  readonly first: number;
  readonly endExclusive: number;
  readonly firstRow: number;
  readonly endRow: number;
}
export class TranscriptStore<T = unknown> {
  private blocks: TranscriptBlock<T>[] = [];
  private ids = new Map<string, number>();
  private epochValue = 0;
  private nextId = 0;
  get epoch(): number { return this.epochValue; }
  get size(): number { return this.blocks.length; }
  get items(): readonly TranscriptBlock<T>[] { return this.blocks; }
  get(index: number): TranscriptBlock<T> | undefined { return this.blocks[index]; }
  indexOf(id: string): number | undefined { return this.ids.get(id); }
  append(kind: string, value: T): TranscriptBlock<T> {
    const block = { id: `${this.epochValue}:${++this.nextId}`, revision: 0, kind, value };
    this.ids.set(block.id, this.blocks.length);
    this.blocks.push(block);
    return block;
  }
  update(id: string, value: T): TranscriptBlock<T> | undefined {
    const index = this.ids.get(id);
    if (index === undefined) return undefined;
    const previous = this.blocks[index]!;
    const block = { ...previous, revision: previous.revision + 1, value };
    this.blocks[index] = block;
    return block;
  }
  truncate(size: number): void {
    if (!Number.isSafeInteger(size) || size < 0 || size > this.blocks.length) {
      throw new RangeError("invalid transcript truncation");
    }
    for (const block of this.blocks.slice(size)) this.ids.delete(block.id);
    this.blocks.length = size;
  }
  reset(): void {
    this.epochValue++;
    this.nextId = 0;
    this.blocks = [];
    this.ids.clear();
  }
}

/**
 * Fenwick tree for measured/estimated terminal row heights. The height of
 * each item must be an integer >=1. Unknown heights use a consistent estimate
 * until their components are measured at the current display width.
 */
export class TranscriptHeightIndex {
  private heights: number[] = [];
  private tree: number[] = [0];
  private widthValue = -1;
  get size(): number { return this.heights.length; }
  get width(): number { return this.widthValue; }
  get totalRows(): number { return this.prefix(this.size); }
  private valid(height: number): number {
    if (!Number.isSafeInteger(height) || height < 1) throw new RangeError("invalid row height");
    return height;
  }
  private rebuild(): void {
    this.tree = new Array(this.heights.length + 1).fill(0);
    for (let index = 0; index < this.heights.length; index++) {
      const node = index + 1;
      this.tree[node] += this.heights[index]!;
      const parent = node + (node & -node);
      if (parent < this.tree.length) this.tree[parent] += this.tree[node]!;
    }
  }
  replace(heights: readonly number[], width: number): void {
    this.heights = heights.map((height) => this.valid(height));
    this.widthValue = width;
    this.rebuild();
  }
  append(height: number): void {
    this.heights.push(this.valid(height));
    // Amortized growth is O(log N), including the preceding power-of-two
    // range, rather than only adding the new value into an empty tree node.
    const i = this.heights.length;
    let value = this.heights[i - 1]!;
    const start = i - (i & -i);
    for (let j = i - 1; j > start; j -= j & -j) value += this.tree[j]!;
    this.tree.push(value);
  }
  update(index: number, height: number): void {
    if (index < 0 || index >= this.size) throw new RangeError("invalid block index");
    const next = this.valid(height), delta = next - this.heights[index]!;
    this.heights[index] = next;
    for (let i = index + 1; i < this.tree.length; i += i & -i) this.tree[i] += delta;
  }
  truncate(size: number): void {
    if (!Number.isSafeInteger(size) || size < 0 || size > this.size) throw new RangeError("invalid height truncation");
    this.heights.length = size;
    this.rebuild();
  }
  heightAt(index: number): number {
    if (index < 0 || index >= this.size) throw new RangeError("invalid block index");
    return this.heights[index]!;
  }
  /** Sum of heights in [0,index), O(log N). */
  prefix(index: number): number {
    if (!Number.isSafeInteger(index) || index < 0 || index > this.size) throw new RangeError("invalid prefix index");
    let sum = 0;
    for (let i = index; i > 0; i -= i & -i) sum += this.tree[i]!;
    return sum;
  }
  /** Find block containing the row, or size when the row is past the end. */
  rowToIndex(row: number): number {
    if (!Number.isFinite(row) || row < 0) return 0;
    if (row >= this.totalRows) return this.size;
    let index = 0, sum = 0, bit = 1;
    while (bit * 2 <= this.size) bit *= 2;
    while (bit > 0) {
      const next = index + bit;
      if (next <= this.size && sum + this.tree[next]! <= row) {
        index = next;
        sum += this.tree[next]!;
      }
      bit = Math.floor(bit / 2);
    }
    return index;
  }
  range(top: number, viewportRows: number, overscanRows = 10): TranscriptVisibleRange {
    const start = Math.max(0, Math.floor(top) - overscanRows);
    const end = Math.min(this.totalRows, Math.max(start, Math.floor(top) + Math.max(0,viewportRows) + overscanRows));
    const first = this.rowToIndex(start);
    const endExclusive = end >= this.totalRows ? this.size : Math.min(this.size, this.rowToIndex(end) + 1);
    return { first, endExclusive, firstRow: this.prefix(first), endRow: this.prefix(endExclusive) };
  }
  anchorAt(top: number, blocks: readonly {id:string}[]): TranscriptAnchor | undefined {
    const index = this.rowToIndex(top);
    const block = blocks[index];
    return block ? {id:block.id,localRow:Math.max(0,Math.floor(top)-this.prefix(index))}:undefined;
  }
  restoreAnchor(anchor: TranscriptAnchor, findIndex: (id:string)=>number|undefined): number | undefined {
    const index=findIndex(anchor.id);
    return index === undefined ? undefined :
      this.prefix(index) + Math.min(this.heights[index]! - 1, Math.max(0,anchor.localRow));
  }
}
