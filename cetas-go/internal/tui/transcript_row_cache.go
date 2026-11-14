package tui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// The transcript paints a window of rows, never a window of whole blocks:
//
//   - transcriptBlockLayout maps a block's source lines onto display rows with
//     cumulative checkpoints, so any row range costs O(rows) instead of
//     O(block).
//   - transcriptRowCache keeps the most recently painted row pages and the
//     layout metadata inside a hard byte budget, so no row is split, padded or
//     ANSI-scanned twice while it stays near the viewport.
//
// Source text is never copied: `lines` are substrings of the formatted block.
const (
	// transcriptRowCacheBudget is the hard byte budget, accounted on every insert
	// so a long session cannot grow it silently.
	transcriptRowCacheBudget = 8 << 20
	// transcriptLayoutStride is the source lines between two row checkpoints, so
	// a lookup scans at most this many lines.
	transcriptLayoutStride = 32
	// transcriptRowPageSize is the materialization granularity: a small scroll
	// reuses the entire page it was reading.
	transcriptRowPageSize = 64
	// transcriptGapDefault is the inter-message gap a block contributes as leading
	// blank rows.
	transcriptGapDefault = 1
	// transcriptGapToolRun is the gap inside a run of consecutive tool calls:
	// dense stacking.
	transcriptGapToolRun = 0
	// transcriptLayoutOversized marks a block whose metadata does not belong in a
	// long-lived cache: it is dropped as soon as it scrolls away.
	transcriptLayoutOversized = transcriptRowCacheBudget / 4
	// transcriptRowCacheEntries bounds the number of cached blocks, so a scroll
	// through a long session of tiny messages stays cheap to trim.
	transcriptRowCacheEntries = 1024
)

// transcriptLayoutIdentity is everything a block's rows depend on: a layout is
// reused only while every input is identical, which is what makes a cached row
// never a stale row.
type transcriptLayoutIdentity struct {
	revision uint64
	width    int
	theme    string
	tools    bool
	thinking bool
	// gap is this block's leading blank-row count; a neighbour that changes the
	// gap invalidates the cached rows instead of serving a stale height.
	gap int
}

// transcriptBlockLayout is one block's source-to-row mapping: `checks[k]` is the
// content rows before source line k*transcriptLayoutStride, so resolving a row
// never scans the whole block.
type transcriptBlockLayout struct {
	block int
	id    transcriptLayoutIdentity
	// gap is the block's leading blank rows; leading, not trailing, so
	// appending a block never re-lays-out its predecessor.
	gap      int
	lines    []string
	lineRows []int32
	ascii    []bool
	checks   []int32
	content  int32
	// bytes is this layout's share of the budget: source text, line headers,
	// checkpoints and row pages.
	bytes    int
	pages    map[int][]string
	cached   bool
	oversize bool
	// frame is the last mount that painted this layout; trim uses it to keep the
	// visible window without allocating a protection set.
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
		gap:      max(0, id.gap),
		lines:    lines,
		lineRows: make([]int32, len(lines)),
		ascii:    make([]bool, len(lines)),
		checks:   make([]int32, 0, 1+len(lines)/transcriptLayoutStride),
		pages:    nil,
	}
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

// Printable ASCII maps one byte to one cell, so a window inside a megabyte of
// JSON or base64 slices only its visible bytes; ANSI and grapheme-heavy lines keep
// ansi.Cut's exact semantics.
func printableASCIILine(line string) bool {
	for i := 0; i < len(line); i++ {
		if line[i] < 0x20 || line[i] > 0x7e {
			return false
		}
	}
	return true
}

func (l *transcriptBlockLayout) height() int { return l.gap + int(l.content) }

// The same arithmetic wrapTranscriptBlock applies.
func transcriptLineRows(line string, width int) int {
	return max(1, (ansi.StringWidth(line)+max(1, width)-1)/max(1, width))
}

// Mirrors bubbles' SoftWrap (cell-accurate ansi.Cut chunks) for a single line, so
// a row range never splits the whole block.
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

// The checkpoint search bounds the scan to transcriptLayoutStride lines.
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

// Content rows first, then the spacer rows, all padded to the transcript width;
// only that range is ever laid out.
func (l *transcriptBlockLayout) rowsInto(dst []string, from, to int) []string {
	width := max(1, l.id.width)
	height := l.height()
	from = clampInt(from, 0, height)
	to = clampInt(to, from, height)
	if from < l.gap {
		blank := strings.Repeat(" ", width)
		for row := from; row < min(to, l.gap); row++ {
			dst = append(dst, blank)
		}
	}
	content := l.gap + int(l.content)
	limit := min(to, content)
	line, offset := -1, 0
	for row := max(from, l.gap); row < limit; row++ {
		if line < 0 {
			line, offset = l.lineAt(row - l.gap)
		}
		source := l.lines[line]
		start := offset * width
		var piece string
		if l.ascii[line] {
			piece = source[min(start, len(source)):min(start+width, len(source))]
		} else if l.lineRows[line] == 1 {
			piece = source
		} else {
			// Cut just the requested row: complex ANSI costs a source scan per
			// visible row, but no whole-line row array is ever allocated.
			piece = ansi.Cut(source, start, start+width)
		}
		dst = append(dst, padTranscriptRow(piece, width))
		offset++
		if offset >= int(l.lineRows[line]) {
			offset = 0
			line++
		}
	}
	return dst
}

// transcriptRowCache is a byte-bounded LRU of block layouts and their row pages.
// An entry is dropped once its block is no longer near the viewport.
type transcriptRowCache struct {
	budget     int
	used       int
	head, tail *transcriptBlockLayout
	byBlock    map[int]*transcriptBlockLayout
	oversized  []*transcriptBlockLayout
	// builds counts layouts derived from source, pages counts row pages
	// materialized; both stay flat on a warm frame, which makes a scroll
	// measurable.
	builds    int
	pages     int
	evictions int
	// frame is the current mount; a layout it painted is never evicted.
	frame uint64
}

func newTranscriptRowCache(budget int) *transcriptRowCache {
	return &transcriptRowCache{budget: max(0, budget), byBlock: make(map[int]*transcriptBlockLayout)}
}

// Everything read or written from now on belongs to the window being painted and
// survives this frame's trim.
func (c *transcriptRowCache) beginFrame() {
	c.frame++
}

func (c *transcriptRowCache) lookup(block int, id transcriptLayoutIdentity) *transcriptBlockLayout {
	layout, ok := c.byBlock[block]
	if !ok {
		return nil
	}
	if layout.id != id {
		// The block changed: its rows are wrong, not merely stale.
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

// Whole pages are read so a small scroll never re-splits a row. The caller owns
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

// The seam the mount path and the selection/copy path share.
func (c *transcriptRowCache) rows(layout *transcriptBlockLayout, from, to int) []string {
	height := layout.height()
	from = clampInt(from, 0, height)
	to = clampInt(to, from, height)
	return c.appendRows(make([]string, 0, to-from), layout, from, to)
}

// A warm frame must leave every counter unchanged, so tests can assert reuse
// instead of inferring it from timings.
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

// Runs after the window's rows are handed to the frame: the current window is
// preferred, but never at the cost of the byte or entry budget. Eviction drops
// cache ownership rather than frame-owned strings, so an oversized layout may be
// derived again on revisit.
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
