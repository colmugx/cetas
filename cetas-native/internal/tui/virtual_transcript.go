package tui

import (
	"math"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
)

// virtualTranscript is the source-independent row index behind the Bubble Tea
// viewport: a Fenwick tree resolves a logical row in O(log messages), and only
// blocks intersecting the viewport plus a small overscan are mounted.
type virtualTranscript struct {
	width, height  int
	top            int
	followEnd      bool
	heights        []int
	bit            []int // 1-based Fenwick tree
	first, end     int
	mountedRows    int
	renderedBlocks int
	// revisions bump when a block's source changes, so the row cache keys a
	// layout on identity instead of on rendered text.
	revisions []uint64
	// rows is the byte-bounded cache of wrapped rows: scrolling inside one long
	// block reuses them instead of re-splitting and re-scanning ANSI.
	rows *transcriptRowCache
	// history renders cold settled blocks too large to lay out on the frame that
	// mounts them. It starts lazily, serves exactly one goroutine, and stops with
	// the document.
	history *historyMarkdownWorker
	// epoch identifies the block layout: a structural edit moves block indices,
	// so a cold render queued against the previous layout never lands on the new
	// one.
	epoch uint64
	// jumpBlock is the block a jump pinned to the viewport, -1 for ordinary
	// scrolling. The mount pass re-anchors on it so growth in the blocks above
	// cannot eject the block the user jumped to.
	jumpBlock int
	// refreshes counts mounted frames, so the reducer can prove a single
	// presentation pass per Update without reading the viewport contents.
	refreshes uint64
}

const virtualOverscanRows = 8

func newVirtualTranscript(width, height int) *virtualTranscript {
	return &virtualTranscript{
		jumpBlock: -1,
		width:     max(1, width), height: max(1, height), followEnd: true, bit: []int{0},
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
	// A reset is a new document: no cold render dispatched against the old one
	// can apply.
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

// One worker serves one document, like the streaming pipeline.
func (v *virtualTranscript) historyMarkdown() *historyMarkdownWorker {
	if v.history == nil {
		v.history = newHistoryMarkdownWorker(historyMarkdownQueueDepth)
	}
	return v.history
}

// A missing entry reads as 0: the revision of a block never edited.
func (v *virtualTranscript) revisionAt(index int) uint64 {
	if index < 0 || index >= len(v.revisions) {
		return 0
	}
	return v.revisions[index]
}

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
	// The new entry covers [i-lowbit+1, i]; earlier entries hold all but the
	// height just appended.
	prior := v.prefix(i-1) - v.prefix(i-lowbit)
	v.heights = append(v.heights, height)
	v.bit = append(v.bit, prior+height)
}

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

// Raw text only, no Markdown render; the estimate is corrected once the block is
// mounted and measured at the terminal's real width.
func estimateTranscriptHeight(raw string, width int) int {
	width = max(1, width)
	rows := 1 // inter-message gap; corrected when the block is mounted
	for _, line := range strings.Split(raw, "\n") {
		rows += max(1, int(math.Ceil(float64(lipgloss.Width(line))/float64(width))))
	}
	return max(3, rows)
}

// The user panel's exact shape: frame rows plus content wrapped at the padded
// inner width. The generic routine undershoots, and a block that grows on mount
// pushes the window's tail out from under the user.
func estimateUserBlockHeight(raw string, width int) int {
	inner := max(10, max(1, width)-4)
	rows := 2 // the panel's blank frame rows; the gap is zero
	for _, line := range strings.Split(raw, "\n") {
		rows += max(1, int(math.Ceil(float64(lipgloss.Width(line))/float64(inner))))
	}
	return max(3, rows)
}

func (m *model) estimateBlockHeight(index int, raw string, width int) int {
	if m.blockKindAt(index) == "user" {
		return estimateUserBlockHeight(raw, width)
	}
	return estimateTranscriptHeight(raw, width)
}

// sync extends incrementally on append; a width change or a shorter session
// rebuilds once, not on every token.
func (v *virtualTranscript) sync(count, width, height int, rawAt func(int) string, estimateAt func(int, string) int) {
	width = max(1, width)
	height = max(1, height)
	// A structural edit (a paged replay insertion) grows the Fenwick tree
	// without growing the revision vector: block indices moved, so no cached row
	// survives it. A *longer* vector is the ordinary append-then-invalidate case
	// and must not flush the window the user is reading.
	if v.rows == nil {
		v.rows = newTranscriptRowCache(transcriptRowCacheBudget)
	} else if len(v.revisions) < len(v.heights) {
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
			v.epoch++
		}
		v.heights = nil
		v.bit = []int{0}
		// Wrapping and padding are width-dependent; neither cache may outlive it.
		v.rows.reset()
	}
	v.width = width
	v.height = height
	for i := len(v.heights); i < count; i++ {
		v.appendHeight(estimateAt(i, rawAt(i)))
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

// rotateVirtualWindow moves `count` heights from `from` down to `at` (at <
// from) inside the Fenwick row index, remapping the viewport's anchor block so
// the reader stays on the same content. A structural move re-keys every block,
// so the row cache resets under a fresh epoch, exactly like a paged insertion;
// the revision vector rotates with the blocks when it is long enough, and is
// shortened otherwise so sync() sees the structural edit.
func rotateVirtualWindow(v *virtualTranscript, at, from, count int) {
	if v == nil || at < 0 || from <= at || from+count > len(v.heights) {
		return
	}
	anchor, offset := 0, 0
	if !v.followEnd && len(v.heights) > 0 {
		anchor = v.indexAt(v.top)
		offset = v.top - v.prefix(anchor)
	}
	run := append([]int(nil), v.heights[from:from+count]...)
	mid := append([]int(nil), v.heights[at:from]...)
	copy(v.heights[at:], run)
	copy(v.heights[at+count:], mid)
	if len(v.revisions) >= from+count {
		revRun := append([]uint64(nil), v.revisions[from:from+count]...)
		revMid := append([]uint64(nil), v.revisions[at:from]...)
		copy(v.revisions[at:], revRun)
		copy(v.revisions[at+count:], revMid)
	} else {
		v.revisions = v.revisions[:at]
	}
	prefix := make([]int, len(v.heights)+1)
	for i, h := range v.heights {
		prefix[i+1] = prefix[i] + h
	}
	v.bit = make([]int, len(v.heights)+1)
	for i := 1; i <= len(v.heights); i++ {
		v.bit[i] = prefix[i] - prefix[i-(i&-i)]
	}
	v.epoch++
	if v.rows != nil {
		v.rows.reset()
	}
	if !v.followEnd {
		v.top = v.prefix(rotateIndex(anchor, at, from, count)) + offset
		v.clamp()
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
	// Centre rather than pin to the top edge: heights are estimates that settle as
	// pages mount, and a top-pinned block at a zero-margin edge slips out of its
	// own window the moment a neighbour above it grows.
	span := v.heightAt(index)
	v.top = clampInt(v.prefix(index)-max(0, (v.height-span)/2), 0, max(0, v.totalRows()-v.height))
	v.jumpBlock = index
	v.followEnd = false
}

// The original source, including the transient streaming and reasoning blocks
// that have not yet settled into history.
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

// Full-width rows are what let a user surface, a selection inversion and the
// scrollbar column cover the whole document instead of stopping at the last
// glyph. Rows are never truncated here: the caller already wrapped them.
func padTranscriptRow(line string, width int) string {
	if width <= 0 {
		return line
	}
	visible := ui.CachedWidth(line)
	if visible < width {
		return line + strings.Repeat(" ", width-visible)
	}
	return line
}

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

// The whole-block view of the same layout the mount path paints by range, so a
// copy or a selection can never disagree with the screen.
func (m *model) mountedTranscriptRows(index int) []string {
	width := max(1, m.viewport.Width())
	layout := newTranscriptBlockLayout(index, transcriptLayoutIdentity{width: width, gap: m.transcriptGap(index)}, m.transcriptBlockText(index))
	return layout.rowsInto(make([]string, 0, layout.height()), 0, layout.height())
}

// Padded to the transcript width so live, replayed, reasoned and tool rows share
// exactly one presentation.
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
		// Streaming answers re-mount every frame; the last source+width render is
		// reused until a delta arrives.
		return m.renderLiveMarkdown(index, raw)
	}
	if rendered, ok := m.markdownCache.get(index); ok {
		return m.decorateAssistant(index, rendered)
	}
	if len(raw) > historyMarkdownSyncLimit && m.dispatchHistoryMarkdown(index, raw) {
		// A giant settled block must not lay out glamour on the update path: it
		// shows its truthful plain source until the background render lands.
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

// It sits directly above the streaming answer, which is the order the settled
// transcript keeps.
func (m *model) liveThinkingIndex() int {
	if m.reasoning == "" {
		return -1
	}
	return len(m.transcript)
}

// pi-tui's ThinkingComponent in live mode: a braille spinner and the trailing
// three lines. The layout belongs to the transcript block renderer, so the model
// supplies only the source and the clock's frame.
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
	m.replayLiveFrom, m.replayLiveSession = 0, ""
	// A session switch is a new document: an in-flight render for the previous
	// one can never reach the new transcript.
	if m.document.markdown != nil {
		m.document.markdown.stop()
	}
	m.document = documentState{}
}
func (m *model) invalidateTranscriptBlock(index int) {
	m.markdownCache.delete(index)
	if m.document.live.valid && m.document.live.index == index {
		m.document.live.valid = false
		// Supersede any render queued for the previous content.
		m.document.live.revision++
	}
	if v := m.virtualScroll; v != nil {
		v.bumpRevision(index)
		if v.history != nil {
			v.history.drop(index)
		}
		if index >= 0 && index < len(v.heights) {
			v.setHeight(index, m.estimateBlockHeight(index, m.rawTranscriptBlock(index), v.width))
		}
	}
}
func (m *model) scrollTranscript(delta int) {
	if m.virtualScroll == nil {
		return
	}
	m.virtualScroll.jumpBlock = -1
	wasTop, wasFollow := m.virtualScroll.top, m.virtualScroll.followEnd
	selection := m.document.selection
	m.virtualScroll.scroll(delta)
	m.touchTranscriptScrollbar()
	if m.virtualScroll.top == wasTop && m.virtualScroll.followEnd == wasFollow && !selection.active {
		// Clamped at an edge with no selection: no row moved, so a mount would
		// rebuild the identical frame.
		return
	}
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

// Every field is part of the row-cache identity, so flipping ctrl+o or ctrl+t,
// resizing or a palette change can never paint the previous shape.
type transcriptMount struct {
	width    int
	theme    string
	tools    bool
	thinking bool
}

// Unknown wire phases settle too: an unrecognized phase must not animate forever.
func settledToolState(state string) bool {
	return transcriptui.ParseToolPhase(state).Terminal()
}

// Animated blocks — the live reasoning spinner, a running tool's elapsed label —
// are rebuilt on every frame: their text is a function of the clock, not of their
// source.
func (m *model) blockLayoutIdentity(v *virtualTranscript, index int, mount transcriptMount) (transcriptLayoutIdentity, bool) {
	id := transcriptLayoutIdentity{width: mount.width, theme: mount.theme, tools: mount.tools, thinking: mount.thinking, gap: m.transcriptGap(index)}
	if index >= len(m.transcript) {
		if index == m.liveThinkingIndex() {
			return id, false
		}
		// The streaming answer keeps the identity of its last completed render, so
		// a frame without a delta reuses its rows.
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

// The blank-row count block `index` contributes above its content. The gap is
// leading and keyed on the predecessor only, so appending a block lays out the
// new block alone and never invalidates its neighbour.
func (m *model) transcriptGap(index int) int {
	if index <= 0 {
		return 0
	}
	switch {
	case m.blockKindAt(index) == "tool" && m.blockKindAt(index-1) == "tool":
		return transcriptGapToolRun
	case m.blockKindAt(index) == "user":
		// The panel's frame rows are the separation; a plain gap would only add a
		// third separator row and drift the mounted height.
		return 0
	default:
		return transcriptGapDefault
	}
}

// A replayed page without block metadata reports "", which degrades to the
// default gap instead of guessing.
func (m *model) blockKindAt(index int) string {
	if b, ok := m.blocks[index]; ok {
		return b.Kind
	}
	return ""
}

// Only the requested row range is ever laid out, so a giant block costs the same
// as a short one.
func (m *model) blockLayout(v *virtualTranscript, index int, mount transcriptMount) *transcriptBlockLayout {
	id, cacheable := m.blockLayoutIdentity(v, index, mount)
	// The streaming answer changes source without a block revision, so its cache
	// lookup has to follow the text lookup, not precede it.
	live := index >= len(m.transcript) && index != m.liveThinkingIndex()
	if cacheable && !live {
		if cached := v.rows.lookup(index, id); cached != nil {
			return cached
		}
	}
	text := m.transcriptBlockText(index)
	if cacheable && live {
		// Asking for the text may have just dispatched a render, so re-check the
		// identity before laying out the new source.
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

// The viewport plus its overscan above and below; blocks are clipped to that
// range, so a block taller than the terminal is never mounted whole.
func (v *virtualTranscript) transcriptWindow() (top, bottom int) {
	top = max(0, v.top-virtualOverscanRows)
	bottom = min(v.top+v.height+virtualOverscanRows, v.totalRows())
	return top, max(top, bottom)
}

// Replaces the estimate of every block intersecting [top, bottom) with its exact
// height. This is the only pass that may lay out cold source.
func (m *model) measureMountedBlocks(v *virtualTranscript, mount transcriptMount, top, bottom int) {
	for i := v.indexAt(top); i < len(v.heights); i++ {
		if v.prefix(i) >= bottom {
			return
		}
		v.setHeight(i, m.blockLayout(v, i, mount).height())
	}
}

// A partially mounted block starts at `top`, not at its first row, so base is
// always the window row: otherwise a block taller than the terminal returns a
// document offset the viewport cannot address.
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

// A bounded mounted window: search highlights, character selection and the
// scrollbar are painted onto the mounted rows only, so nothing here renders
// offscreen history.
func (m *model) refreshTranscript() {
	m.presentation.snapshot = nil
	// A reducer may request several refreshes (a scroll, then reflow); the frame
	// guard defers all but the final layout pass of one Update.
	if !m.beginTranscriptMount() {
		return
	}
	m.pumpLiveMarkdown()
	if m.virtualScroll == nil {
		m.virtualScroll = newVirtualTranscript(m.viewport.Width(), m.viewport.Height())
	}
	v := m.virtualScroll
	count := m.transcriptBlockCount()
	width := m.viewport.Width()
	v.sync(count, width, m.viewport.Height(), m.rawTranscriptBlock, func(index int, raw string) int {
		return m.estimateBlockHeight(index, raw, width)
	})
	// Applied before this frame measures the block, so its height describes the
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
	// Everything read or materialized here belongs to the frame and must survive
	// its trim.
	v.rows.beginFrame()
	// The row under the user's eye is kept, so a cold mount never jumps the
	// scroll position.
	anchor := v.indexAt(v.top)
	if v.jumpBlock >= 0 && v.jumpBlock < len(v.heights) {
		// A jump's target outranks the row under the top: neighbours settling from
		// estimates to true heights move rows under a fixed anchor, and the target
		// is the one row that must not slip out.
		anchor = v.jumpBlock
	}
	intra := clampInt(v.top-v.prefix(anchor), 0, max(0, v.heightAt(anchor)-1))
	top, bottom := v.transcriptWindow()
	for pass := 0; ; pass++ {
		m.measureMountedBlocks(v, mount, top, bottom)
		// Exact heights change the document length, so the anchor is resolved after
		// them and before any row is painted.
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
	// Proportional to the window, not the session; reflow discards it on resize.
	m.markdownCache.retain(start, end)
	m.paintTranscriptScrollbar(lines, v.top-base)
	m.viewport.SetContentLines(lines)
	// A wheel notch inside one block keeps the offset at the overscan row, so
	// setting it again would only rebuild the same scroll limits.
	if offset := v.top - base; m.viewport.YOffset() != offset {
		m.viewport.SetYOffset(offset)
	}
}

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
