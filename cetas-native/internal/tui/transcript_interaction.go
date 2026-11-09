package tui

import (
	"math"
	"regexp"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// Pi-tui's ScrollView auto scrollbar hides again after a second without
// activity; the same delay is applied here so the terminal does not keep a
// permanent column on a wide conversation.
const transcriptScrollbarHideDelay = time.Second

// transcriptPoint is a document coordinate: a logical transcript row as
// resolved by the Fenwick height tree, and a display column in terminal cells.
// Rows are absolute, so a drag can span blocks that are not mounted.
type transcriptPoint struct{ row, col int }

// documentState is the interactive state of the virtual transcript document:
// the last live Markdown render, the character selection and the scrollbar
// gesture. It holds no runtime, permission or session authority; the parent
// reducer may copy it by value.
type documentState struct {
	live      liveMarkdown
	selection transcriptSelection
	scrollbar transcriptScrollbarState
	// markdown is the bounded background Markdown worker. It starts lazily on
	// the first superseded streaming source and stops with the document.
	markdown *markdownPipeline
	// onCopy replaces the terminal clipboard writer. Tests and reviewers use
	// it to observe the copied source without an actual OSC52 write.
	onCopy func(string) tea.Cmd
}

// liveMarkdown is the streaming block's render state. Deltas change the source
// but every clock frame re-mounts the same block, so only a new source, width
// or theme may dispatch another render. `source` is the newest requested
// source and `rendered` the newest completed one: the screen keeps the last
// finished render until a validated result replaces it, which is why streaming
// never blocks Update and never flashes raw Markdown.
type liveMarkdown struct {
	valid    bool
	index    int
	width    int
	themeKey string
	source   string
	rendered string
	// revision increments for every dispatched source and is echoed back by
	// the worker, so a render of a superseded source, width or theme is
	// dropped instead of painted.
	revision uint64
	// renderedRevision is the revision whose output is currently displayed.
	renderedRevision uint64
	// renders counts dispatched Markdown renders, including the synchronous
	// first frame of a block; tests assert that unchanged frames do not
	// repeat a full render.
	renders int
}

type transcriptSelection struct {
	anchor, focus transcriptPoint
	active        bool
}

func (s transcriptSelection) start() transcriptPoint {
	if s.anchor.row < s.focus.row || (s.anchor.row == s.focus.row && s.anchor.col <= s.focus.col) {
		return s.anchor
	}
	return s.focus
}

func (s transcriptSelection) end() transcriptPoint {
	if s.anchor.row < s.focus.row || (s.anchor.row == s.focus.row && s.anchor.col <= s.focus.col) {
		return s.focus
	}
	return s.anchor
}

type transcriptScrollbarState struct {
	hover    bool
	dragging bool
	grab     int
	hideAt   time.Time
}

// ansiSGR matches SGR styling so inverse video can be re-applied after the
// resets colored content emits inside a selected range.
var ansiSGR = regexp.MustCompile("\x1b\\[[0-?]*[ -/]*m")

// transcriptScrollbarTrack is the pi-tui auto-scrollbar geometry, expressed in
// rows relative to the transcript region rather than absolute screen rows.
type transcriptScrollbarTrack struct {
	TrackTop     int
	TrackHeight  int
	ThumbTop     int
	ThumbHeight  int
	MaxScrollTop int
}

// transcriptScrollbarGeometry mirrors pi-tui getScrollbarGeometry. It reports a
// track only for a document taller than the viewport: a scrollbar for content
// that fits would be a phantom affordance.
func transcriptScrollbarGeometry(totalRows, top, height int) (transcriptScrollbarTrack, bool) {
	if height <= 0 || totalRows <= height {
		return transcriptScrollbarTrack{}, false
	}
	thumb := max(min(2, height), min(height, int(math.Round(float64(height*height)/float64(totalRows)))))
	maxScrollTop := totalRows - height
	maxThumbTop := height - thumb
	offset := 0
	if maxScrollTop > 0 {
		offset = int(math.Round(float64(clampInt(top, 0, maxScrollTop)) / float64(maxScrollTop) * float64(maxThumbTop)))
	}
	return transcriptScrollbarTrack{
		TrackTop:     0,
		TrackHeight:  height,
		ThumbTop:     offset,
		ThumbHeight:  thumb,
		MaxScrollTop: maxScrollTop,
	}, true
}

func clampInt(value, low, high int) int { return min(max(value, low), high) }

// transcriptRegion is the viewport hit target. Width and height come from the
// viewport itself so a mouse row always maps onto a mounted document row.
type transcriptRegion struct{ X, Y, Width, Height int }

func (r transcriptRegion) contains(x, y int) bool {
	return x >= r.X && x < r.X+r.Width && y >= r.Y && y < r.Y+r.Height
}

func (m *model) transcriptRegion() transcriptRegion {
	return transcriptRegion{
		X:      0,
		Y:      len(m.presentedRegions().header),
		Width:  max(1, m.viewport.Width()),
		Height: max(1, m.viewport.Height()),
	}
}

// renderLiveMarkdown renders a still-streaming block without ever laying out
// Markdown on the update/paint path. The first frame of a block is rendered
// synchronously exactly once — the terminal must not flash raw Markdown and
// there is no previous render to keep — and every later delta is dispatched to
// the bounded worker. The last finished render stays on screen until a result
// whose revision, width and theme still match replaces it.
func (m *model) renderLiveMarkdown(index int, raw string) string {
	if m.markdownRenderer == nil {
		return raw
	}
	width := max(1, m.viewport.Width())
	themeKey := m.markdownThemeIdentity()
	cache := &m.document.live
	if len(raw) > maxWholeMarkdownSourceBytes {
		// A stream can cross the safety bound after a smaller prefix rendered.
		// Keep its complete newest source visible, not that obsolete prefix,
		// and supersede older in-flight results without scheduling another AST.
		if !cache.valid || cache.index != index || cache.width != width || cache.themeKey != themeKey || cache.source != raw {
			revision := cache.revision + 1
			*cache = liveMarkdown{valid: true, index: index, width: width, themeKey: themeKey,
				source: raw, rendered: raw, revision: revision, renderedRevision: revision, renders: cache.renders}
			m.err = "Markdown render deferred: " + wholeMarkdownBudgetError().Error()
		}
		return cache.rendered
	}
	if !cache.valid || cache.index != index || cache.width != width || cache.themeKey != themeKey {
		rendered, err := renderMarkdown(m.markdownRenderer, raw)
		if err != nil {
			m.err = "Markdown render failed: " + err.Error()
			rendered = raw
		}
		// A new block, width or theme supersedes every render in flight.
		revision := cache.revision + 1
		renders := cache.renders + 1
		*cache = liveMarkdown{
			valid: true, index: index, width: width, themeKey: themeKey,
			source: raw, rendered: rendered,
			revision: revision, renderedRevision: revision, renders: renders,
		}
		return rendered
	}
	if cache.source == raw {
		return cache.rendered
	}
	cache.source = raw
	cache.revision++
	cache.renders++
	if m.document.markdown == nil {
		m.document.markdown = newMarkdownPipeline()
	}
	m.document.markdown.submit(markdownRenderJob{
		revision: cache.revision,
		width:    width,
		themeKey: themeKey,
		theme:    m.theme(),
		source:   raw,
	})
	return cache.rendered
}

// pumpLiveMarkdown applies completed background renders that still describe the
// streaming block. A result of a superseded source, width or theme is discarded:
// the worker's identity is validated, never assumed. It never blocks, so the
// frame that already exists absorbs the result.
func (m *model) pumpLiveMarkdown() {
	pipeline := m.document.markdown
	if pipeline == nil {
		return
	}
	cache := &m.document.live
	for {
		result, ok := pipeline.take()
		if !ok {
			return
		}
		if !cache.valid || result.width != cache.width || result.themeKey != cache.themeKey ||
			result.revision <= cache.renderedRevision || result.revision > cache.revision {
			continue
		}
		if result.err != nil {
			m.err = "Markdown render failed: " + result.err.Error()
			continue
		}
		cache.rendered = result.rendered
		cache.renderedRevision = result.revision
	}
}

// markdownRenderPending reports whether a background render is still queued,
// running or unpainted. The parent's nextUIWake can treat it like an animation,
// so a stream that stops without a settling event still paints its last render.
func (m *model) markdownRenderPending() bool {
	pipeline := m.document.markdown
	return pipeline != nil && !pipeline.idle()
}

// transcriptPointAt maps a terminal cell onto a document coordinate. Rows are
// clamped into the visible window: the pointer never selects history that the
// viewport is not showing.
func (m *model) transcriptPointAt(x, y int) (transcriptPoint, bool) {
	v := m.virtualScroll
	if v == nil {
		return transcriptPoint{}, false
	}
	total := v.totalRows()
	if total <= 0 {
		return transcriptPoint{}, false
	}
	region := m.transcriptRegion()
	row := v.top + clampInt(y-region.Y, 0, region.Height-1)
	col := clampInt(x-region.X, 0, region.Width-1)
	return transcriptPoint{row: clampInt(row, 0, total-1), col: col}, true
}

// handleTranscriptMouse implements pi-tui's transcript hit target for the
// virtual document: left-button character selection, release-triggered copy
// and auto-scrollbar dragging. Wheel and non-left buttons stay with the parent.
// The boolean reports whether this handler consumed the message.
func (m *model) handleTranscriptMouse(message tea.MouseMsg) (tea.Cmd, bool) {
	if m.virtualScroll == nil || m.modal != "" || m.modalRequestID != "" {
		return nil, false
	}
	switch msg := message.(type) {
	case tea.MouseClickMsg:
		if msg.Button != tea.MouseLeft {
			return nil, false
		}
		return m.transcriptMousePress(msg.X, msg.Y)
	case tea.MouseMotionMsg:
		switch msg.Button {
		case tea.MouseLeft:
			return m.transcriptMouseDrag(msg.X, msg.Y)
		case tea.MouseNone:
			return nil, m.scrollbarHoverAt(msg.X, msg.Y)
		}
		return nil, false
	case tea.MouseReleaseMsg:
		// SGR releases may report either the released button or "none".
		if msg.Button == tea.MouseRight || msg.Button == tea.MouseMiddle {
			return nil, false
		}
		return m.transcriptMouseRelease(msg.X, msg.Y)
	}
	return nil, false
}

func (m *model) transcriptMousePress(x, y int) (tea.Cmd, bool) {
	region := m.transcriptRegion()
	if !region.contains(x, y) {
		return nil, false
	}
	if track, ok := m.scrollbarTrackAt(x, y); ok {
		m.document.selection = transcriptSelection{}
		row := y - region.Y
		onThumb := row >= track.ThumbTop && row < track.ThumbTop+track.ThumbHeight
		grab := track.ThumbHeight / 2
		if onThumb {
			grab = row - track.ThumbTop
		}
		m.document.scrollbar = transcriptScrollbarState{hover: true, dragging: true, grab: grab}
		if !onThumb {
			m.scrollScrollbarToPointer(track, row)
		} else {
			m.touchTranscriptScrollbar()
			m.refreshTranscript()
		}
		return nil, true
	}
	// While the document is scrolled away from the end, the last visible row
	// is the "newer messages" action. It is a jump to the tail, not a
	// selection press.
	if !m.virtualScroll.followEnd && y == region.Y+region.Height-1 {
		m.transcriptScrollToEnd()
		return nil, true
	}
	point, ok := m.transcriptPointAt(x, y)
	if !ok {
		return nil, false
	}
	m.document.selection = transcriptSelection{anchor: point, focus: point, active: true}
	m.refreshTranscript()
	return nil, true
}

func (m *model) transcriptMouseDrag(x, y int) (tea.Cmd, bool) {
	if m.document.scrollbar.dragging {
		track, ok := transcriptScrollbarGeometry(
			m.virtualScroll.totalRows(), m.virtualScroll.top, m.viewport.Height())
		if !ok {
			return nil, true
		}
		m.scrollScrollbarToPointer(track, clampInt(y-m.transcriptRegion().Y, 0, max(0, track.TrackHeight-1)))
		return nil, true
	}
	selection := &m.document.selection
	if !selection.active {
		// CellMotion reports drags after a press elsewhere; without our own
		// press this gesture is not a transcript selection.
		return nil, false
	}
	point, ok := m.transcriptPointAt(x, y)
	if !ok {
		return nil, true
	}
	selection.focus = point
	m.refreshTranscript()
	return nil, true
}

func (m *model) transcriptMouseRelease(x, y int) (tea.Cmd, bool) {
	if m.document.scrollbar.dragging {
		// Keep hover: the pointer is still on the scrollbar column, and
		// pi-tui only clears it when the pointer leaves the track.
		m.document.scrollbar.dragging = false
		m.document.scrollbar.grab = 0
		m.touchTranscriptScrollbar()
		m.refreshTranscript()
		return nil, true
	}
	if !m.document.selection.active {
		return nil, false
	}
	if point, ok := m.transcriptPointAt(x, y); ok {
		m.document.selection.focus = point
	}
	selection := m.document.selection
	if m.replay.active() && m.virtualScroll != nil && selection.start() != selection.end() {
		first := m.virtualScroll.indexAt(selection.start().row)
		last := m.virtualScroll.indexAt(selection.end().row)
		if first != last {
			m.document.selection = transcriptSelection{}
			m.refreshTranscript()
			return m.pagedCopyRangeCommand(first, last), true
		}
	}
	text, ok := m.transcriptSelectionText()
	// Release always repaints: no persistent inverse-video highlight and no
	// click-only selection, independent of clipboard success.
	m.document.selection = transcriptSelection{}
	m.refreshTranscript()
	if !ok || text == "" {
		return nil, true
	}
	if m.document.onCopy != nil {
		return m.document.onCopy(text), true
	}
	m.status = "copied transcript selection to clipboard"
	return tea.SetClipboard(text), true
}

// transcriptSelectionText returns the source text under the current selection.
// A selection inside one block copies the selected cells of that block; a
// selection spanning blocks copies the original source of every covered block,
// which is the only way to be exact about history that was never mounted.
func (m *model) transcriptSelectionText() (string, bool) {
	v := m.virtualScroll
	selection := m.document.selection
	if v == nil || !selection.active {
		return "", false
	}
	start, end := selection.start(), selection.end()
	if start == end {
		return "", false
	}
	first := v.indexAt(start.row)
	last := v.indexAt(end.row)
	if first != last {
		text, err := m.copySourceRange(first, last)
		if err != nil || text == "" {
			return "", false
		}
		return text, true
	}
	// Within one block, copy the selected characters rather than the whole
	// message. Terminal columns are cells, not byte or ANSI offsets.
	if first < v.first || first >= v.end {
		// Never render unmounted history just to satisfy a copy.
		return "", false
	}
	rows := m.mountedTranscriptRows(first)
	base := v.prefix(first)
	lines := make([]string, 0, end.row-start.row+1)
	for row := start.row; row <= end.row; row++ {
		index := row - base
		if index < 0 || index >= len(rows) {
			continue
		}
		line := rows[index]
		from := 0
		if row == start.row {
			from = start.col
		}
		to := ansi.StringWidth(line)
		if row == end.row {
			to = min(to, end.col+1)
		}
		if to <= from {
			lines = append(lines, "")
			continue
		}
		lines = append(lines, strings.TrimRight(ansi.Strip(ansi.Cut(line, from, to)), " "))
	}
	// The two inter-message spacer rows are a native layout artifact; a
	// selection that ends on them must not add trailing blank lines.
	for len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	text := strings.Join(lines, "\n")
	if text == "" {
		return "", false
	}
	return text, true
}

func (m *model) scrollbarTrackAt(x, y int) (transcriptScrollbarTrack, bool) {
	region := m.transcriptRegion()
	if x != region.X+region.Width-1 {
		return transcriptScrollbarTrack{}, false
	}
	return transcriptScrollbarGeometry(m.virtualScroll.totalRows(), m.virtualScroll.top, region.Height)
}

// scrollbarHoverAt reveals the auto scrollbar when the pointer is on its
// column and reports whether any visible state changed.
func (m *model) scrollbarHoverAt(x, y int) bool {
	region := m.transcriptRegion()
	hovering := false
	if region.contains(x, y) {
		_, hovering = m.scrollbarTrackAt(x, y)
	}
	if hovering == m.document.scrollbar.hover {
		return false
	}
	m.document.scrollbar.hover = hovering
	m.refreshTranscript()
	return true
}

func (m *model) scrollScrollbarToPointer(track transcriptScrollbarTrack, row int) {
	maxThumbTop := track.TrackHeight - track.ThumbHeight
	offset := clampInt(row-m.document.scrollbar.grab, 0, max(0, maxThumbTop))
	top := 0
	if maxThumbTop > 0 {
		top = int(math.Round(float64(offset) / float64(maxThumbTop) * float64(track.MaxScrollTop)))
	}
	m.setTranscriptTop(top)
}

// transcriptScrollToEnd re-arms end-following: the action of pi-tui's
// "newer messages" indicator.
func (m *model) transcriptScrollToEnd() {
	v := m.virtualScroll
	if v == nil {
		return
	}
	v.followEnd = true
	v.clamp()
	m.touchTranscriptScrollbar()
	m.refreshTranscript()
}

// setTranscriptTop moves the document to an absolute row and re-enables
// end-following only when the bottom is reached, matching ScrollView.scrollTo.
func (m *model) setTranscriptTop(top int) {
	v := m.virtualScroll
	if v == nil {
		return
	}
	bottom := max(0, v.totalRows()-v.height)
	v.top = clampInt(top, 0, bottom)
	v.followEnd = v.top >= bottom
	m.touchTranscriptScrollbar()
	m.refreshTranscript()
}

func (m *model) touchTranscriptScrollbar() {
	m.document.scrollbar.hideAt = time.Now().Add(transcriptScrollbarHideDelay)
}

func (m *model) transcriptScrollbarVisible(now time.Time) bool {
	if m.document.scrollbar.dragging || m.document.scrollbar.hover {
		return true
	}
	return !m.document.scrollbar.hideAt.IsZero() && now.Before(m.document.scrollbar.hideAt)
}

// paintTranscriptScrollbar draws the visible auto scrollbar on the mounted
// lines. Rows are region-relative, so the track stays aligned with the window
// even though the mounted slice includes overscan above the offset.
func (m *model) paintTranscriptScrollbar(lines []string, yOffset int) {
	v := m.virtualScroll
	if v == nil {
		return
	}
	width := m.viewport.Width()
	track, ok := transcriptScrollbarGeometry(v.totalRows(), v.top, m.viewport.Height())
	if !ok || width <= 0 || !m.transcriptScrollbarVisible(time.Now()) {
		return
	}
	theme := m.theme()
	active := m.document.scrollbar.dragging || m.document.scrollbar.hover
	thumb := "┃"
	if active {
		thumb = "█"
	}
	trackCell := theme.Role("muted", "│")
	thumbCell := theme.Role("accent", thumb)
	for row := 0; row < track.TrackHeight; row++ {
		index := yOffset + track.TrackTop + row
		if index < 0 || index >= len(lines) {
			continue
		}
		cell := trackCell
		if row >= track.ThumbTop && row < track.ThumbTop+track.ThumbHeight {
			cell = thumbCell
		}
		lines[index] = replaceTranscriptCell(ui.Pad(lines[index], width), width-1, cell)
	}
}

// replaceTranscriptCell replaces one display cell, keeping every other cell and
// the row's visible width intact.
func replaceTranscriptCell(line string, column int, replacement string) string {
	width := ansi.StringWidth(line)
	if column < 0 || column >= width {
		return line
	}
	return ansi.Cut(line, 0, column) + replacement + ansi.Cut(line, column+1, width)
}

// paintTranscriptSelectionRow inverts the selected cells of one mounted row.
// A cross-block selection selects whole rows, exactly like the source-indexed
// clipboard text it produces.
func (m *model) paintTranscriptSelectionRow(line string, row, first, last int, start, end transcriptPoint) string {
	if !m.document.selection.active || first < 0 || last < 0 || row < start.row || row > end.row {
		return line
	}
	width := ansi.StringWidth(line)
	from, to := 0, width
	if first == last {
		if row == start.row {
			from = start.col
		}
		if row == end.row {
			to = min(to, end.col+1)
		}
	}
	return invertTranscriptCells(line, from, to)
}

func invertTranscriptCells(line string, from, to int) string {
	width := ansi.StringWidth(line)
	from = clampInt(from, 0, width)
	to = clampInt(to, 0, width)
	if to <= from {
		return line
	}
	before := ansi.Cut(line, 0, from)
	middle := ansi.Cut(line, from, to)
	after := ansi.Cut(line, to, width)
	// Reapply inversion after the resets colored Markdown leaves behind.
	inverted := ansiSGR.ReplaceAllStringFunc(middle, func(code string) string { return code + "\x1b[7m" })
	return before + "\x1b[7m" + inverted + "\x1b[27m" + after
}
