package tui

import (
	"math"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
)

// virtualTranscript is the source-independent row index behind the Bubble Tea
// viewport. A Fenwick tree resolves a logical row in O(log messages). Only
// blocks intersecting the viewport and a small overscan window are mounted.
// Nothing here stores rendered text from offscreen messages.
type virtualTranscript struct {
	width, height  int
	top            int
	followEnd      bool
	heights        []int
	bit            []int // 1-based Fenwick tree
	first, end     int
	mountedRows    int
	renderedBlocks int
	// revisions bump whenever a block's source changes, so the row cache can
	// key a layout on identity instead of on rendered text.
	revisions []uint64
	// rows is the byte-bounded cache of formatted/wrapped rows behind the
	// mounted window. Scrolling inside one long block reuses it instead of
	// re-splitting, re-padding and re-scanning ANSI on every event.
	rows *transcriptRowCache
	// history is the document's background renderer for cold settled blocks
	// too large to lay out on the frame that mounts them. It starts lazily on
	// the first giant block, serves exactly one goroutine, and stops with the
	// document.
	history *historyMarkdownWorker
	// epoch identifies the current block layout. A structural edit (a paged
	// insertion or a shorter session) moves block indices, so a cold render
	// queued against the previous layout must never be applied to the new one.
	epoch uint64
	// refreshes counts mounted frames. The parent reducer can compare it across
	// one Update to prove a single presentation pass, without guessing from the
	// viewport contents.
	refreshes uint64
}

const virtualOverscanRows = 8

func newVirtualTranscript(width, height int) *virtualTranscript {
	return &virtualTranscript{
		width: max(1, width), height: max(1, height), followEnd: true, bit: []int{0},
		rows: newTranscriptRowCache(transcriptRowCacheBudget),
	}
}
func (v *virtualTranscript) reset() {
	v.heights = nil
	v.bit = []int{0}
	v.top = 0
	v.followEnd = true
	v.first = 0
	v.end = 0
	v.mountedRows = 0
	v.renderedBlocks = 0
	v.revisions = nil
	// A reset is a new document: block indices and their sources no longer mean
	// what a queued or completed cold render was dispatched against.
	v.epoch++
	if v.history != nil {
		v.history.stop()
		v.history = nil
	}
	if v.rows == nil {
		v.rows = newTranscriptRowCache(transcriptRowCacheBudget)
	} else {
		v.rows.reset()
	}
}

// historyMarkdown returns the document's cold settled-block worker, starting it
// on first use. One worker serves one document, like the streaming pipeline.
func (v *virtualTranscript) historyMarkdown() *historyMarkdownWorker {
	if v.history == nil {
		v.history = newHistoryMarkdownWorker(historyMarkdownQueueDepth)
	}
	return v.history
}

// revisionAt is the source revision of one block. A missing entry is 0, which
// is the revision of a block that has never been edited.
func (v *virtualTranscript) revisionAt(index int) uint64 {
	if index < 0 || index >= len(v.revisions) {
		return 0
	}
	return v.revisions[index]
}

// bumpRevision invalidates the cached rows of one block after its source or
// render inputs changed.
func (v *virtualTranscript) bumpRevision(index int) {
	if index < 0 {
		return
	}
	for len(v.revisions) <= index {
		v.revisions = append(v.revisions, 0)
	}
	v.revisions[index]++
}

func (v *virtualTranscript) prefix(i int) int {
	i = min(max(i, 0), len(v.heights))
	sum := 0
	for i > 0 {
		sum += v.bit[i]
		i -= i & -i
	}
	return sum
}
func (v *virtualTranscript) totalRows() int { return v.prefix(len(v.heights)) }
func (v *virtualTranscript) heightAt(i int) int {
	if i < 0 || i >= len(v.heights) {
		return 1
	}
	return v.heights[i]
}
func (v *virtualTranscript) setHeight(i, height int) {
	if i < 0 || i >= len(v.heights) {
		return
	}
	height = max(1, height)
	delta := height - v.heights[i]
	if delta == 0 {
		return
	}
	v.heights[i] = height
	for j := i + 1; j < len(v.bit); j += j & -j {
		v.bit[j] += delta
	}
}
func (v *virtualTranscript) appendHeight(height int) {
	height = max(1, height)
	i := len(v.heights) + 1
	lowbit := i & -i
	// The new Fenwick entry covers [i-lowbit+1, i]; previous entries
	// already contain all but the just-appended height.
	prior := v.prefix(i-1) - v.prefix(i-lowbit)
	v.heights = append(v.heights, height)
	v.bit = append(v.bit, prior+height)
}

// indexAt resolves the block containing the given logical row in O(log N).
func (v *virtualTranscript) indexAt(row int) int {
	n := len(v.heights)
	if n == 0 {
		return 0
	}
	row = min(max(0, row), max(0, v.totalRows()-1))
	index := 0
	for step := 1 << uint(bitsForIndex(n)); step > 0; step >>= 1 {
		next := index + step
		if next <= n && v.bit[next] <= row {
			row -= v.bit[next]
			index = next
		}
	}
	return min(index, n-1)
}
func bitsForIndex(n int) int {
	bits := 0
	for 1<<uint(bits) <= n {
		bits++
	}
	return bits
}

// Estimates require only raw text, not a Markdown render. They are corrected
// as each block is mounted and measured in the terminal's actual width.
func estimateTranscriptHeight(raw string, width int) int {
	width = max(1, width)
	rows := 2 // between-message spacer, also retained for the final block
	for _, line := range strings.Split(raw, "\n") {
		rows += max(1, int(math.Ceil(float64(lipgloss.Width(line))/float64(width))))
	}
	return max(3, rows)
}

// sync extends incrementally on append. Width changes and wholesale session
// replacements rebuild the index once, not every token or keypress.
func (v *virtualTranscript) sync(count, width, height int, rawAt func(int) string) {
	width = max(1, width)
	height = max(1, height)
	// A structural edit outside the append path (a paged replay insertion)
	// grows the Fenwick tree without growing the revision vector: block indices
	// moved, so no cached row can survive it. A *longer* vector is the ordinary
	// "a just-appended block was edited" case (append then invalidate, before
	// the next sync) and must not flush the window the user is reading.
	if v.rows == nil {
		v.rows = newTranscriptRowCache(transcriptRowCacheBudget)
	} else if len(v.revisions) < len(v.heights) {
		// A structural edit moved block indices, so a cold render queued against
		// the old positions can no longer be trusted for the new ones.
		v.epoch++
		v.rows.reset()
	}
	if len(v.revisions) > len(v.heights) {
		v.revisions = v.revisions[:len(v.heights)]
	}
	widthChanged := v.width != width
	anchor, offset := 0, 0
	if widthChanged && len(v.heights) > 0 && !v.followEnd {
		anchor = v.indexAt(v.top)
		offset = v.top - v.prefix(anchor)
	}
	if widthChanged || count < len(v.heights) {
		if count < len(v.heights) {
			// A shorter session is a different document: indices below it now
			// name different blocks.
			v.epoch++
		}
		v.heights = nil
		v.bit = []int{0}
		// Wrapping and padding are width-dependent, and a shorter session is a
		// different document: neither cache may outlive that.
		v.rows.reset()
	}
	v.width = width
	v.height = height
	for i := len(v.heights); i < count; i++ {
		v.appendHeight(estimateTranscriptHeight(rawAt(i), width))
	}
	for len(v.revisions) < count {
		v.revisions = append(v.revisions, 0)
	}
	if len(v.revisions) > count {
		v.revisions = v.revisions[:count]
	}
	if widthChanged && !v.followEnd && len(v.heights) > 0 {
		anchor = min(anchor, len(v.heights)-1)
		v.top = v.prefix(anchor) + min(offset, v.heightAt(anchor)-1)
	}
	v.clamp()
}
func (v *virtualTranscript) clamp() {
	bottom := max(0, v.totalRows()-v.height)
	if v.followEnd {
		v.top = bottom
	} else {
		v.top = min(max(0, v.top), bottom)
	}
}
func (v *virtualTranscript) scroll(delta int) {
	if delta == 0 {
		return
	}
	v.top = min(max(0, v.top+delta), max(0, v.totalRows()-v.height))
	v.followEnd = v.top >= max(0, v.totalRows()-v.height)
}
func (v *virtualTranscript) jumpToBlock(index int) {
	if index < 0 || index >= len(v.heights) {
		return
	}
	v.top = min(v.prefix(index), max(0, v.totalRows()-v.height))
	v.followEnd = false
}

// rawTranscriptBlock uses the original source, including the transient
// streaming and reasoning blocks which have not yet settled into history.
func (m *model) rawTranscriptBlock(index int) string {
	if index < len(m.transcript) {
		return m.transcript[index]
	}
	index -= len(m.transcript)
	if m.reasoning != "" {
		if index == 0 {
			return "Thinking: " + m.reasoning
		}
		index--
	}
	if index == 0 && m.streaming != "" {
		return m.streaming
	}
	return ""
}
func (m *model) transcriptBlockCount() int {
	count := len(m.transcript)
	if m.reasoning != "" {
		count++
	}
	if m.streaming != "" {
		count++
	}
	return count
}

// wrapTranscriptBlock splits a block into the rows the viewport will paint.
// It mirrors bubbles' SoftWrap (cell-accurate ansi.Cut chunks), so measured
// heights, painted rows and selection coordinates all agree.
func wrapTranscriptBlock(text string, width int) []string {
	width = max(1, width)
	rows := make([]string, 0, 4)
	for _, line := range strings.Split(text, "\n") {
		lineWidth := ansi.StringWidth(line)
		if lineWidth <= width {
			rows = append(rows, line)
			continue
		}
		for start := 0; start < lineWidth; start += width {
			rows = append(rows, ansi.Cut(line, start, start+width))
		}
	}
	if len(rows) == 0 {
		rows = []string{""}
	}
	return rows
}

// padTranscriptRow fills one row to the transcript width, the way pi-tui pads
// every Markdown/Text line: content keeps its single-cell left margin and each
// row is exactly `width` cells. Full-width rows are what let a user surface, a
// selection inversion and the auto scrollbar column cover the whole document
// instead of stopping at the last glyph. Rows are never truncated here — the
// caller already wrapped them.
func padTranscriptRow(line string, width int) string {
	if width <= 0 {
		return line
	}
	if visible := ansi.StringWidth(line); visible < width {
		return line + strings.Repeat(" ", width-visible)
	}
	return line
}

// padTranscriptBlock pads every row of one block to the transcript width.
func padTranscriptBlock(text string, width int) string {
	if width <= 0 || text == "" {
		return text
	}
	lines := strings.Split(text, "\n")
	for i := range lines {
		lines[i] = padTranscriptRow(lines[i], width)
	}
	return strings.Join(lines, "\n")
}

// mountedTranscriptRows is the exact row set a block contributes to the
// document: its wrapped content plus the two inter-message spacer rows. Rows
// are padded to the transcript width, including the spacers, so the document
// has no ragged right edge. It is the whole-block view of the same layout the
// mount path paints by range, so a copy or a selection can never disagree with
// the screen.
func (m *model) mountedTranscriptRows(index int) []string {
	width := max(1, m.viewport.Width())
	layout := newTranscriptBlockLayout(index, transcriptLayoutIdentity{width: width}, m.transcriptBlockText(index))
	return layout.rowsInto(make([]string, 0, layout.height()), 0, layout.height())
}

// mountedTranscriptBlock is one block's display text before the caller wraps it
// into rows. It is padded to the transcript width so live, replayed, reasoned
// and tool rows share exactly one presentation.
func (m *model) mountedTranscriptBlock(index int) string {
	return padTranscriptBlock(m.transcriptBlockText(index), m.viewport.Width())
}

func (m *model) transcriptBlockText(index int) string {
	if rendered, ok := m.renderBlock(index); ok {
		return rendered
	}
	raw := m.rawTranscriptBlock(index)
	if index == m.liveThinkingIndex() {
		return m.liveThinkingPreview()
	}
	_, markdown := m.markdownRaw[index]
	if index >= len(m.transcript) {
		markdown = true
	}
	if !markdown || m.markdownRenderer == nil {
		return raw
	}
	if index >= len(m.transcript) {
		// Streaming answers are re-mounted on every UI frame; the last
		// source+width render is reused until a delta arrives.
		return m.renderLiveMarkdown(index, raw)
	}
	if rendered, ok := m.markdownCache.get(index); ok {
		return m.decorateAssistant(index, rendered)
	}
	if len(raw) > historyMarkdownSyncLimit && m.dispatchHistoryMarkdown(index, raw) {
		// A giant settled block must not lay out glamour on the update path.
		// Until the background render lands, the block shows its truthful plain
		// source; the pump replaces these rows with the finished layout.
		return m.decorateAssistant(index, raw)
	}
	rendered, err := renderMarkdown(m.markdownRenderer, raw)
	if err != nil {
		m.err = "Markdown render failed: " + err.Error()
		rendered = raw
	}
	m.markdownCache.put(index, rendered)
	return m.decorateAssistant(index, rendered)
}

// liveThinkingIndex is the document position of the transient reasoning block,
// or -1 while no reasoning has streamed. It sits directly above the streaming
// answer, which is the order the settled transcript keeps.
func (m *model) liveThinkingIndex() int {
	if m.reasoning == "" {
		return -1
	}
	return len(m.transcript)
}

// liveThinkingPreview is pi-tui's ThinkingComponent in live mode: a braille
// spinner with "thinking..." and only the trailing three lines of reasoning that
// have arrived so far. The layout itself belongs to the transcript block
// renderer (the JS oracle), so the model supplies only the source and the shell
// clock's animation frame; the finalized block keeps the collapsed header and
// its leading lines instead.
func (m *model) liveThinkingPreview() string {
	theme := m.theme()
	return transcriptui.Block{Kind: "thinking", Text: m.reasoning}.Render(transcriptui.Options{
		Width:        m.viewport.Width(),
		ThinkingLive: true,
		Frame:        m.surface.frame,
		Styles:       transcriptui.Styles{Muted: func(s string) string { return theme.Role("muted", s) }},
	})
}

func (m *model) resetVirtualTranscript() {
	if m.virtualScroll != nil {
		m.virtualScroll.reset()
	}
	m.markdownCache.reset()
	// A session switch is a new document: selection, scrollbar, the live
	// Markdown render and the background renderer all belong to the previous
	// one, so an in-flight result can never reach the new transcript.
	if m.document.markdown != nil {
		m.document.markdown.stop()
	}
	m.document = documentState{}
}
func (m *model) invalidateTranscriptBlock(index int) {
	m.markdownCache.delete(index)
	if m.document.live.valid && m.document.live.index == index {
		m.document.live.valid = false
		// Supersede any render already queued for the previous content.
		m.document.live.revision++
	}
	if v := m.virtualScroll; v != nil {
		// The block's source changed: its cached rows describe the old one.
		v.bumpRevision(index)
		if v.history != nil {
			// A queued or completed cold render for the old source is dead work.
			v.history.drop(index)
		}
		if index >= 0 && index < len(v.heights) {
			v.setHeight(index, estimateTranscriptHeight(m.rawTranscriptBlock(index), v.width))
		}
	}
}
func (m *model) scrollTranscript(delta int) {
	if m.virtualScroll == nil {
		return
	}
	wasTop, wasFollow := m.virtualScroll.top, m.virtualScroll.followEnd
	selection := m.document.selection
	m.virtualScroll.scroll(delta)
	// A wheel or key scroll reveals the auto scrollbar for one second.
	m.touchTranscriptScrollbar()
	if m.virtualScroll.top == wasTop && m.virtualScroll.followEnd == wasFollow && !selection.active {
		// Clamped at an edge with no selection: no row moved, so a full
		// window mount would rebuild the identical frame.
		return
	}
	// Character selection is tied to rows that just moved.
	m.document.selection = transcriptSelection{}
	m.refreshTranscript()
}
func (m *model) jumpToTranscriptBlock(index int) {
	if m.virtualScroll == nil {
		return
	}
	m.virtualScroll.jumpToBlock(index)
	m.refreshTranscript()
}

// transcriptMount is the display configuration that decides how a block lays
// out. Every field is part of the row-cache identity, so flipping ctrl+o or
// ctrl+t, resizing or a palette change can never paint the previous shape.
type transcriptMount struct {
	width    int
	theme    string
	tools    bool
	thinking bool
}

// settledToolState reports a terminal tool row: its label no longer animates.
// Unknown wire phases settle too — an unrecognized phase must not animate
// forever.
func settledToolState(state string) bool {
	return transcriptui.ParseToolPhase(state).Terminal()
}

// blockLayoutIdentity decides whether a block's rows may be cached. Animated
// blocks — the live reasoning spinner and a running tool's elapsed label — are
// rebuilt on every frame because their text is a function of the clock, not of
// their source.
func (m *model) blockLayoutIdentity(v *virtualTranscript, index int, mount transcriptMount) (transcriptLayoutIdentity, bool) {
	id := transcriptLayoutIdentity{width: mount.width, theme: mount.theme, tools: mount.tools, thinking: mount.thinking}
	if index >= len(m.transcript) {
		if index == m.liveThinkingIndex() {
			return id, false
		}
		// The streaming answer keeps the identity of its last completed
		// background render, so a frame without a delta reuses its rows.
		live := m.document.live
		if !live.valid || live.index != index || live.width != mount.width || live.themeKey != mount.theme {
			return id, false
		}
		id.revision = live.renderedRevision
		return id, true
	}
	if b, ok := m.blocks[index]; ok && b.Kind == "tool" && !settledToolState(b.State) && !b.Started.IsZero() {
		return id, false
	}
	id.revision = v.revisionAt(index)
	return id, true
}

// blockLayout returns the row mapping of one block, from the cache when its
// identity is unchanged and freshly derived otherwise. Only the requested row
// range is ever laid out; a giant block costs the same as a short one.
func (m *model) blockLayout(v *virtualTranscript, index int, mount transcriptMount) *transcriptBlockLayout {
	id, cacheable := m.blockLayoutIdentity(v, index, mount)
	// The streaming answer changes source without a block revision, so its
	// cache lookup has to follow the text prefix, not precede it.
	live := index >= len(m.transcript) && index != m.liveThinkingIndex()
	if cacheable && !live {
		if cached := v.rows.lookup(index, id); cached != nil {
			return cached
		}
	}
	text := m.transcriptBlockText(index)
	if cacheable && live {
		// A streaming answer's source can advance without a block revision: its
		// identity is the last completed render, which asking for the text may
		// have just dispatched. Re-check before laying out the new source.
		if id, cacheable = m.blockLayoutIdentity(v, index, mount); cacheable {
			if cached := v.rows.lookup(index, id); cached != nil {
				return cached
			}
		}
	}
	layout := newTranscriptBlockLayout(index, id, text)
	if cacheable {
		v.rows.store(layout)
	}
	return layout
}

// transcriptWindow is the row range a frame paints: the viewport plus the same
// overscan above and below it. Blocks are clipped to this range, so a block
// taller than the terminal is never mounted whole.
func (v *virtualTranscript) transcriptWindow() (top, bottom int) {
	top = max(0, v.top-virtualOverscanRows)
	bottom = min(v.top+v.height+virtualOverscanRows, v.totalRows())
	return top, max(top, bottom)
}

// measureMountedBlocks replaces the row estimate of every block intersecting
// [top, bottom) with its exact height. This is the only frame that may lay out
// cold source; every later frame reads the cache.
func (m *model) measureMountedBlocks(v *virtualTranscript, mount transcriptMount, top, bottom int) {
	for i := v.indexAt(top); i < len(v.heights); i++ {
		if v.prefix(i) >= bottom {
			return
		}
		v.setHeight(i, m.blockLayout(v, i, mount).height())
	}
}

// mountTranscriptWindow assembles the padded rows of [top, bottom) and returns
// the painted lines together with the row their first entry represents. A
// partially mounted block starts at `top`, not at its first row, so base is
// always the window row: a block taller than the terminal would otherwise
// return a document offset the viewport cannot address.
func (m *model) mountTranscriptWindow(v *virtualTranscript, count int, mount transcriptMount, top, bottom int) ([]string, int, int, int) {
	start := v.indexAt(top)
	base := top
	lines := make([]string, 0, v.height+2*virtualOverscanRows+8)
	first, last := m.transcriptSelectionBlocks()
	var selStart, selEnd transcriptPoint
	if first >= 0 {
		selStart, selEnd = m.document.selection.start(), m.document.selection.end()
	}
	v.renderedBlocks = 0
	end := start
	for i := start; i < count; i++ {
		blockStart := v.prefix(i)
		if blockStart >= bottom {
			break
		}
		layout := m.blockLayout(v, i, mount)
		v.setHeight(i, layout.height())
		blockEnd := blockStart + layout.height()
		from := max(top, blockStart) - blockStart
		to := min(bottom, blockEnd) - blockStart
		begin := len(lines)
		if to > from {
			lines = v.rows.appendRows(lines, layout, from, to)
			if hits := hitsAt(m.searchHits, i); len(hits) > 0 {
				// Highlighting rewrites only the rows of this window slice.
				copy(lines[begin:], highlightLiteralRows(lines[begin:], m.transcriptSourceAt(i), hits, v.width))
			}
			for offset := begin; offset < len(lines); offset++ {
				lines[offset] = m.paintTranscriptSelectionRow(lines[offset], blockStart+from+offset-begin, first, last, selStart, selEnd)
			}
			v.renderedBlocks++
		}
		end = i + 1
	}
	v.rows.trim()
	return lines, base, start, end
}

// refreshTranscript now makes a bounded mounted window. All movement and
// redraw paths use this method, but never join the complete conversation.
// Search highlights, character selection and the auto scrollbar are painted
// onto the mounted rows only; nothing here renders offscreen history.
func (m *model) refreshTranscript() {
	m.presentation.snapshot = nil
	// A reducer may request several refreshes (a scroll, then reflow). The
	// parent's frame guard defers all but the final layout pass of one Update,
	// so one input cannot mount the document twice.
	if !m.beginTranscriptMount() {
		return
	}
	// A background Markdown render that already finished is applied on this
	// frame, before the block is mounted.
	m.pumpLiveMarkdown()
	if m.virtualScroll == nil {
		m.virtualScroll = newVirtualTranscript(m.viewport.Width(), m.viewport.Height())
	}
	v := m.virtualScroll
	count := m.transcriptBlockCount()
	v.sync(count, m.viewport.Width(), m.viewport.Height(), m.rawTranscriptBlock)
	// A cold settled block that finished in the background is applied before
	// this frame measures and mounts it, so its rows and height describe the
	// render rather than the plain fallback.
	m.pumpHistoryMarkdown()
	v.refreshes++
	if count == 0 {
		v.first, v.end = 0, 0
		v.mountedRows = 0
		v.renderedBlocks = 0
		v.rows.trim()
		m.viewport.SetContent("")
		m.viewport.SetYOffset(0)
		return
	}
	mount := transcriptMount{
		width:    max(1, m.viewport.Width()),
		theme:    m.markdownThemeIdentity(),
		tools:    m.showTools,
		thinking: m.showThinking,
	}
	// Everything this mount reads or materializes belongs to the frame and must
	// survive the cache trim at its end.
	v.rows.beginFrame()
	// The row under the user's eye is kept while estimates above it settle into
	// exact heights, so a cold mount never jumps the scroll position.
	anchor := v.indexAt(v.top)
	intra := v.top - v.prefix(anchor)
	top, bottom := v.transcriptWindow()
	for pass := 0; ; pass++ {
		m.measureMountedBlocks(v, mount, top, bottom)
		// Exact heights change the document length, so the scroll anchor is
		// resolved after them and before a single row is painted.
		if v.followEnd {
			v.top = max(0, v.totalRows()-v.height)
		} else {
			v.top = min(max(0, v.prefix(anchor)+min(intra, v.heightAt(anchor)-1)), max(0, v.totalRows()-v.height))
		}
		nextTop, nextBottom := v.transcriptWindow()
		if pass >= 2 || (nextTop == top && nextBottom == bottom) {
			top, bottom = nextTop, nextBottom
			break
		}
		top, bottom = nextTop, nextBottom
	}
	lines, base, start, end := m.mountTranscriptWindow(v, count, mount, top, bottom)
	v.first = start
	v.end = end
	v.mountedRows = len(lines)
	// Keep the formatted-text cache proportional to the window, not the
	// session. On resize it is discarded by reflow.
	m.markdownCache.retain(start, end)
	m.paintTranscriptScrollbar(lines, v.top-base)
	m.viewport.SetContentLines(lines)
	// A wheel notch inside one block keeps the window offset at the overscan
	// row, so setting it again would only re-walk the mounted rows to recompute
	// the same scroll limits.
	if offset := v.top - base; m.viewport.YOffset() != offset {
		m.viewport.SetYOffset(offset)
	}
}

// transcriptSelectionBlocks resolves the block range covered by the current
// character selection, or -1 when there is nothing selected.
func (m *model) transcriptSelectionBlocks() (int, int) {
	v := m.virtualScroll
	selection := m.document.selection
	if v == nil || !selection.active {
		return -1, -1
	}
	start, end := selection.start(), selection.end()
	if start == end {
		return -1, -1
	}
	return v.indexAt(start.row), v.indexAt(end.row)
}
