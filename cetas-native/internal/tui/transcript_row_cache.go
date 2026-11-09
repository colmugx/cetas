package tui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// The transcript paints a window of rows, never a window of whole blocks. Two
// structures make that possible without re-laying-out a block on every wheel
// event:
//
//   - transcriptBlockLayout maps a block's source lines onto display rows with
//     cumulative checkpoints, so any row range costs O(rows) instead of
//     O(block). A giant block therefore contributes the same number of rows to
//     a frame as a short one.
//   - transcriptRowCache keeps the most recently painted row pages (and the
//     layout metadata) inside a hard byte budget. Scrolling inside a long block
//     reuses both, so no row is split, padded or ANSI-scanned twice while it
//     stays near the viewport.
//
// Source text is never copied: `lines` are substrings of the formatted block,
// exactly like the render the terminal would have painted before.
const (
	// transcriptRowCacheBudget is the hard byte budget of the cache. It is
	// accounted on every insert, so a long session cannot grow it silently.
	transcriptRowCacheBudget = 8 << 20
	// transcriptLayoutStride is the number of source lines between two
	// cumulative row checkpoints. A row lookup scans at most this many lines.
	transcriptLayoutStride = 32
	// transcriptRowPageSize is the materialization granularity: a wheel event
	// that moves the viewport slightly reuses the entire page it was reading.
	transcriptRowPageSize = 64
	// transcriptRowSpacers is the inter-message gap every block contributes,
	// matching mountedTranscriptRows.
	transcriptRowSpacers = 2
	// transcriptLayoutOversized marks a block whose own metadata does not
	// belong in a long-lived cache. Such a block stays cached only while it is
	// on screen and is dropped as soon as it scrolls away.
	transcriptLayoutOversized = transcriptRowCacheBudget / 4
	// transcriptRowCacheEntries bounds the number of cached blocks so a scroll
	// through a very long session with tiny messages stays cheap to trim.
	transcriptRowCacheEntries = 1024
)

// transcriptLayoutIdentity is everything a block's rows depend on. A layout is
// reused only while every input is identical, which is what makes a cached row
// never a stale row: the block revision, terminal width, theme and the
// tool/thinking expansion flags all invalidate it.
type transcriptLayoutIdentity struct {
	revision uint64
	width    int
	theme    string
	tools    bool
	thinking bool
}

// transcriptBlockLayout is one block's source-to-row mapping. `checks[k]` is
// the number of content rows before source line k*transcriptLayoutStride, so
// resolving a row never scans the whole block.
type transcriptBlockLayout struct {
	block    int
	id       transcriptLayoutIdentity
	lines    []string
	lineRows []int32
	ascii    []bool
	checks   []int32
	content  int32
	// bytes is this layout's share of the cache budget: its source text, the
	// line headers and the checkpoints, plus every materialized row page.
	bytes    int
	pages    map[int][]string
	cached   bool
	oversize bool
	// frame is the last mount that painted this layout. Trim uses it to keep
	// the visible window without allocating a protection set every frame.
	frame uint64
	prev  *transcriptBlockLayout
	next  *transcriptBlockLayout
}

func newTranscriptBlockLayout(block int, id transcriptLayoutIdentity, text string) *transcriptBlockLayout {
	width := max(1, id.width)
	lines := strings.Split(text, "\n")
	layout := &transcriptBlockLayout{
		block:    block,
		id:       id,
		lines:    lines,
		lineRows: make([]int32, len(lines)),
		ascii:    make([]bool, len(lines)),
		checks:   make([]int32, 0, 1+len(lines)/transcriptLayoutStride),
		pages:    nil,
	}
	// checks[k] is the number of content rows before source line
	// k*transcriptLayoutStride, so checks[0] is always 0.
	layout.checks = append(layout.checks, 0)
	rows := int32(0)
	for index, line := range lines {
		if index > 0 && index%transcriptLayoutStride == 0 {
			layout.checks = append(layout.checks, rows)
		}
		layout.ascii[index] = printableASCIILine(line)
		cells := len(line)
		if !layout.ascii[index] {
			cells = ansi.StringWidth(line)
		}
		layout.lineRows[index] = int32(max(1, (cells+width-1)/width))
		rows += layout.lineRows[index]
	}
	layout.content = rows
	layout.bytes = len(text) + len(lines)*21 + len(layout.checks)*4
	layout.oversize = layout.bytes > transcriptLayoutOversized
	return layout
}

// Printable ASCII has a one-to-one byte/cell map. Keeping this classification
// in the layout lets a window inside a megabyte of JSON/base64 slice only its
// visible bytes; ANSI and grapheme-heavy lines keep ansi.Cut's exact semantics.
func printableASCIILine(line string) bool {
	for i := 0; i < len(line); i++ {
		if line[i] < 0x20 || line[i] > 0x7e {
			return false
		}
	}
	return true
}

// height is the block's real document height: content rows plus the two
// inter-message spacer rows every block owns.
func (l *transcriptBlockLayout) height() int { return int(l.content) + transcriptRowSpacers }

// transcriptLineRows is the number of terminal rows one source line occupies,
// the same arithmetic wrapTranscriptBlock applies.
func transcriptLineRows(line string, width int) int {
	return max(1, (ansi.StringWidth(line)+max(1, width)-1)/max(1, width))
}

// wrapTranscriptLine splits one line into the cells the viewport paints. It
// mirrors bubbles' SoftWrap (cell-accurate ansi.Cut chunks) exactly like
// wrapTranscriptBlock, but for a single line so a row range never splits the
// whole block.
func wrapTranscriptLine(line string, width int) []string {
	width = max(1, width)
	cells := ansi.StringWidth(line)
	if cells <= width {
		return []string{line}
	}
	rows := make([]string, 0, (cells+width-1)/width)
	for start := 0; start < cells; start += width {
		rows = append(rows, ansi.Cut(line, start, start+width))
	}
	return rows
}

// lineAt resolves the source line and the row offset inside it. The checkpoint
// search bounds the scan to transcriptLayoutStride lines.
func (l *transcriptBlockLayout) lineAt(row int) (int, int) {
	row = clampInt(row, 0, max(0, int(l.content)-1))
	low, high := 0, len(l.checks)-1
	for low < high {
		middle := (low + high + 1) / 2
		if int(l.checks[middle]) <= row {
			low = middle
		} else {
			high = middle - 1
		}
	}
	line := low * transcriptLayoutStride
	offset := row - int(l.checks[low])
	for line < len(l.lines)-1 {
		rows := int(l.lineRows[line])
		if offset < rows {
			break
		}
		offset -= rows
		line++
	}
	return line, offset
}

// rowsInto appends the block's display rows [from, to) — content rows first,
// then the spacer rows — padded to the transcript width. Only that range is
// ever laid out.
func (l *transcriptBlockLayout) rowsInto(dst []string, from, to int) []string {
	width := max(1, l.id.width)
	height := l.height()
	from = clampInt(from, 0, height)
	to = clampInt(to, from, height)
	content := int(l.content)
	if from < content {
		line, offset := l.lineAt(from)
		limit := min(to, content)
		for ; line < len(l.lines) && from < limit; line++ {
			source := l.lines[line]
			for ; offset < int(l.lineRows[line]) && from < limit; offset++ {
				start := offset * width
				var piece string
				if l.ascii[line] {
					piece = source[min(start, len(source)):min(start+width, len(source))]
				} else if l.lineRows[line] == 1 {
					piece = source
				} else {
					// Cut just this requested row, not every row in the physical
					// line. Complex ANSI still costs a source scan per visible row;
					// no whole-line row array is ever allocated for a window.
					piece = ansi.Cut(source, start, start+width)
				}
				dst = append(dst, padTranscriptRow(piece, width))
				from++
			}
			offset = 0
		}
	}
	if spacers := to - max(from, content); spacers > 0 {
		blank := strings.Repeat(" ", width)
		for i := 0; i < spacers; i++ {
			dst = append(dst, blank)
		}
	}
	return dst
}

// transcriptRowCache is a byte-bounded LRU of block layouts and their
// materialized row pages. An entry is dropped once its block is no longer near
// the viewport, so an oversized block is never retained just because it was
// once painted.
type transcriptRowCache struct {
	budget     int
	used       int
	head, tail *transcriptBlockLayout
	byBlock    map[int]*transcriptBlockLayout
	oversized  []*transcriptBlockLayout
	// builds counts layouts derived from source, pages counts row pages
	// materialized; both stay flat on a warm frame, which is what makes a
	// scroll measurable instead of guessed.
	builds    int
	pages     int
	evictions int
	// frame is the current mount. A layout painted by it is never evicted.
	frame uint64
}

func newTranscriptRowCache(budget int) *transcriptRowCache {
	return &transcriptRowCache{budget: max(0, budget), byBlock: make(map[int]*transcriptBlockLayout)}
}

// beginFrame starts a mount: everything read or written from now on belongs to
// the window being painted and survives this frame's trim.
func (c *transcriptRowCache) beginFrame() {
	c.frame++
}

func (c *transcriptRowCache) lookup(block int, id transcriptLayoutIdentity) *transcriptBlockLayout {
	layout, ok := c.byBlock[block]
	if !ok {
		return nil
	}
	if layout.id != id {
		// The block changed: its rows are not merely stale, they are wrong.
		c.drop(layout)
		return nil
	}
	c.touch(layout)
	layout.frame = c.frame
	return layout
}

func (c *transcriptRowCache) store(layout *transcriptBlockLayout) {
	if old, ok := c.byBlock[layout.block]; ok {
		c.drop(old)
	}
	layout.cached = true
	layout.frame = c.frame
	layout.prev, layout.next = nil, c.head
	if c.head != nil {
		c.head.prev = layout
	}
	c.head = layout
	if c.tail == nil {
		c.tail = layout
	}
	c.byBlock[layout.block] = layout
	c.used += layout.bytes
	c.builds++
	if layout.oversize {
		c.oversized = append(c.oversized, layout)
	}
}

func (c *transcriptRowCache) drop(layout *transcriptBlockLayout) {
	if layout.prev != nil {
		layout.prev.next = layout.next
	} else {
		c.head = layout.next
	}
	if layout.next != nil {
		layout.next.prev = layout.prev
	} else {
		c.tail = layout.prev
	}
	layout.prev, layout.next = nil, nil
	layout.cached = false
	c.used -= layout.bytes
	delete(c.byBlock, layout.block)
	if layout.oversize {
		for i, oversized := range c.oversized {
			if oversized == layout {
				c.oversized = append(c.oversized[:i], c.oversized[i+1:]...)
				break
			}
		}
	}
}

func (c *transcriptRowCache) touch(layout *transcriptBlockLayout) {
	if c.head == layout {
		return
	}
	if layout.prev != nil {
		layout.prev.next = layout.next
	}
	if layout.next != nil {
		layout.next.prev = layout.prev
	} else {
		c.tail = layout.prev
	}
	layout.prev, layout.next = nil, c.head
	if c.head != nil {
		c.head.prev = layout
	}
	c.head = layout
}

// page materializes (and accounts) one page of a block's rows.
func (c *transcriptRowCache) page(layout *transcriptBlockLayout, index int) []string {
	if rows, ok := layout.pages[index]; ok {
		return rows
	}
	start := index * transcriptRowPageSize
	end := min(start+transcriptRowPageSize, layout.height())
	rows := layout.rowsInto(make([]string, 0, max(0, end-start)), start, end)
	if layout.pages == nil {
		layout.pages = make(map[int][]string, 2)
	}
	layout.pages[index] = rows
	layout.frame = c.frame
	size := 0
	for _, row := range rows {
		size += len(row)
	}
	layout.bytes += size
	c.used += size
	c.pages++
	return rows
}

// appendRows appends the padded display rows [from, to) of one block to dst,
// reading whole pages so a small scroll never re-splits a row. The caller owns
// dst, so a painted row can never mutate a cached page.
func (c *transcriptRowCache) appendRows(dst []string, layout *transcriptBlockLayout, from, to int) []string {
	height := layout.height()
	from = clampInt(from, 0, height)
	to = clampInt(to, from, height)
	if !layout.cached {
		return layout.rowsInto(dst, from, to)
	}
	for from < to {
		index := from / transcriptRowPageSize
		start := index * transcriptRowPageSize
		chunk := c.page(layout, index)
		if start+len(chunk) <= from {
			break
		}
		high := min(len(chunk), to-start)
		dst = append(dst, chunk[from-start:high]...)
		from = start + high
	}
	return dst
}

// rows returns the padded display rows [from, to) of one cached block. It is
// the seam the mount path and the selection/copy path share.
func (c *transcriptRowCache) rows(layout *transcriptBlockLayout, from, to int) []string {
	height := layout.height()
	from = clampInt(from, 0, height)
	to = clampInt(to, from, height)
	return c.appendRows(make([]string, 0, to-from), layout, from, to)
}

// transcriptRowCacheStats is the observable state of the cache. A warm frame
// must leave every counter unchanged, so tests can assert reuse instead of
// inferring it from timings.
type transcriptRowCacheStats struct {
	builds       int
	materialized int
	used         int
	layouts      int
	evictions    int
}

func (c *transcriptRowCache) stats() transcriptRowCacheStats {
	return transcriptRowCacheStats{
		builds:       c.builds,
		materialized: c.pages,
		used:         c.used,
		layouts:      len(c.byBlock),
		evictions:    c.evictions,
	}
}

// trim runs after the window's rows have been handed to the frame. Prefer
// retaining the current window, but never let that preference bypass the byte
// or entry budget. Eviction drops cache ownership, not the frame-owned strings.
// A layout larger than the budget may consequently be derived again on revisit.
func (c *transcriptRowCache) trim() {
	for i := 0; i < len(c.oversized); i++ {
		layout := c.oversized[i]
		if layout.frame == c.frame {
			continue
		}
		c.evict(layout)
		i--
	}
	for len(c.byBlock) > transcriptRowCacheEntries && c.tail != nil {
		if !c.evictOldest() {
			c.evict(c.tail) // only the current window remains; it must fit too
		}
	}
	for c.used > c.budget && c.tail != nil {
		if !c.evictOldest() {
			c.evict(c.tail) // only the current window remains; it must fit too
		}
	}
}

func (c *transcriptRowCache) evictOldest() bool {
	for victim := c.tail; victim != nil; victim = victim.prev {
		if victim.frame == c.frame {
			continue
		}
		c.evict(victim)
		return true
	}
	return false
}

func (c *transcriptRowCache) evict(layout *transcriptBlockLayout) {
	c.drop(layout)
	c.evictions++
}

func (c *transcriptRowCache) reset() {
	for layout := c.head; layout != nil; layout = layout.next {
		layout.cached = false
		layout.prev, layout.next = nil, nil
	}
	c.head, c.tail = nil, nil
	c.byBlock = make(map[int]*transcriptBlockLayout)
	c.oversized = nil
	c.used = 0
}
