package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func interactionModel(t *testing.T, width, height int, blocks ...string) *model {
	t.Helper()
	m := newModel()
	m.width, m.height = width, height
	m.resize()
	m.transcript = append([]string(nil), blocks...)
	m.refreshTranscript()
	// Streaming Markdown starts a background worker; Close it with the test so
	// no goroutine outlives the case that created it. The closure reads the
	// model at cleanup time, after the test has dispatched its deltas.
	out := &m
	t.Cleanup(func() { out.Close() })
	return out
}

func click(x, y int) tea.MouseMsg   { return tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft} }
func release(x, y int) tea.MouseMsg { return tea.MouseReleaseMsg{X: x, Y: y, Button: tea.MouseLeft} }
func drag(x, y int) tea.MouseMsg    { return tea.MouseMotionMsg{X: x, Y: y, Button: tea.MouseLeft} }
func hover(x, y int) tea.MouseMsg   { return tea.MouseMotionMsg{X: x, Y: y, Button: tea.MouseNone} }
func wheelDown(x, y int) tea.MouseMsg {
	return tea.MouseWheelMsg{X: x, Y: y, Button: tea.MouseWheelDown}
}
func rightClick(x, y int) tea.MouseMsg { return tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseRight} }

// A settled message and the still-streaming one must paint identically, so the
// terminal never reflows the same source when the turn completes.
func TestLiveAndFinalMarkdownRenderEquivalence(t *testing.T) {
	m := interactionModel(t, 80, 24)
	m.streaming = "intro **bold**\n\n- one\n- two\n\n> quoted"
	m.refreshTranscript()
	live := m.mountedTranscriptBlock(len(m.transcript))

	m.flushAssistant()
	m.streaming, m.reasoning = "", ""
	m.refreshTranscript()
	final := m.mountedTranscriptBlock(0)
	if live == "" || live != final {
		t.Fatalf("live/final render diverged:\nlive=%q\nfinal=%q", live, final)
	}
}

func TestMouseCharacterSelectionWithinBlock(t *testing.T) {
	m := interactionModel(t, 40, 12, "abcdef")
	region := m.transcriptRegion()
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }

	if _, handled := m.handleTranscriptMouse(click(region.X+4, region.Y)); !handled {
		t.Fatal("left press in the transcript was not handled")
	}
	if _, handled := m.handleTranscriptMouse(drag(region.X+1, region.Y)); !handled {
		t.Fatal("drag in the transcript was not handled")
	}
	if !strings.Contains(m.viewport.GetContent(), "\x1b[7m") {
		t.Fatal("drag did not paint an inverse-video selection")
	}
	if text, ok := m.transcriptSelectionText(); !ok || text != "bcde" {
		t.Fatalf("selection text = %q ok=%v", text, ok)
	}
	if _, handled := m.handleTranscriptMouse(release(region.X+1, region.Y)); !handled {
		t.Fatal("release in the transcript was not handled")
	}
	if copied != "bcde" {
		t.Fatalf("clipboard got %q", copied)
	}
	if strings.Contains(m.viewport.GetContent(), "\x1b[7m") {
		t.Fatal("selection repaint survived release")
	}
	if text, ok := m.transcriptSelectionText(); ok || text != "" {
		t.Fatalf("release kept a selection: %q", text)
	}
}

func TestMouseSingleClickDoesNotSelectOrCopy(t *testing.T) {
	m := interactionModel(t, 40, 12, "plain")
	region := m.transcriptRegion()
	copied := 0
	m.document.onCopy = func(string) tea.Cmd { copied++; return nil }
	m.handleTranscriptMouse(click(region.X+2, region.Y))
	m.handleTranscriptMouse(release(region.X+2, region.Y))
	if copied != 0 {
		t.Fatal("click-only gesture copied text")
	}
	if strings.Contains(m.viewport.GetContent(), "\x1b[7m") {
		t.Fatal("click inverted a block")
	}
}

// Dragging across a long conversation copies the original source of every
// covered message, including history that was never mounted. Offscreen
// Markdown/ToolRow rendering must not be triggered by the gesture.
func TestMouseSelectionAcrossUnmountedBlocksCopiesOriginalSource(t *testing.T) {
	m := newModel()
	m.width, m.height = 60, 20
	m.resize()
	for i := 0; i < 10000; i++ {
		m.appendAssistant(fmt.Sprintf("**bold** %d", i))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	region := m.transcriptRegion()
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }

	m.handleTranscriptMouse(click(region.X, region.Y))
	m.handleTranscriptMouse(drag(region.X, region.Y+region.Height-1))
	selection := m.document.selection
	if !selection.active {
		t.Fatal("cross-block drag lost its selection")
	}
	first, last := v.indexAt(selection.start().row), v.indexAt(selection.end().row)
	if first == last {
		t.Fatalf("drag stayed inside one block: %d", first)
	}
	m.handleTranscriptMouse(release(region.X, region.Y+region.Height-1))

	want, err := m.copySourceRange(first, last)
	if err != nil {
		t.Fatal(err)
	}
	if copied != want {
		t.Fatalf("cross-block copy is not the source concatenation:\n got %q\nwant %q", copied, want)
	}
	if !strings.Contains(copied, "**bold**") || !strings.Contains(copied, fmt.Sprintf("**bold** %d", last)) {
		t.Fatalf("copy lost original Markdown source: %q", copied)
	}
	if m.markdownCache.stats().entries > 100 || v.renderedBlocks > 100 {
		t.Fatalf("copy rendered unmounted history: cache=%d blocks=%d", m.markdownCache.stats().entries, v.renderedBlocks)
	}
}

func TestMouseSelectionIncludesStreamingTailSource(t *testing.T) {
	m := interactionModel(t, 50, 12, "settled one", "settled two")
	m.streaming = "tail **live**"
	m.refreshTranscript()
	region := m.transcriptRegion()
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }
	m.handleTranscriptMouse(click(region.X, region.Y))
	m.handleTranscriptMouse(drag(region.X, region.Y+region.Height-1))
	m.handleTranscriptMouse(release(region.X, region.Y+region.Height-1))
	if !strings.HasSuffix(copied, "tail **live**") {
		t.Fatalf("streaming tail copied rendered text instead of source: %q", copied)
	}
}

func TestTranscriptScrollbarPaintAndDrag(t *testing.T) {
	m := newModel()
	m.width, m.height = 60, 12
	m.resize()
	for i := 0; i < 400; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("row %d", i))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	region := m.transcriptRegion()
	column := region.X + region.Width - 1

	if strings.Contains(m.viewport.GetContent(), "│") {
		t.Fatal("auto scrollbar is painted before any scroll activity")
	}
	if _, handled := m.handleTranscriptMouse(hover(column, region.Y)); !handled {
		t.Fatal("hover over the scrollbar column was not handled")
	}
	content := m.viewport.GetContent()
	// Hovering the track makes the thumb active ("█"), exactly like
	// ScrollView.setScrollbarActive on pointer hover.
	if !strings.Contains(content, "█") || !strings.Contains(content, "│") {
		t.Fatalf("hover did not paint the auto scrollbar: %q", ansi.Strip(content))
	}
	if !m.document.scrollbar.hover {
		t.Fatal("hover state not tracked")
	}
	// The track is the visible window, not the mounted overscan lines.
	visible := strings.Split(content, "\n")[m.viewport.YOffset():]
	for i, line := range visible[:min(len(visible), region.Height)] {
		want := "│"
		geometry, _ := transcriptScrollbarGeometry(v.totalRows(), v.top, region.Height)
		if i >= geometry.ThumbTop && i < geometry.ThumbTop+geometry.ThumbHeight {
			want = "█"
		}
		if !strings.HasSuffix(ansi.Strip(line), want) {
			t.Fatalf("scrollbar column misaligned on visible row %d: %q", i, ansi.Strip(line))
		}
	}

	// Leaving the column hides the hover but a recent scroll keeps the auto
	// scrollbar on screen with an inactive thumb.
	if _, handled := m.handleTranscriptMouse(hover(region.X+1, region.Y)); !handled {
		t.Fatal("leaving the scrollbar column was not handled")
	}
	if m.document.scrollbar.hover {
		t.Fatal("hover survived leaving the column")
	}
	m.scrollTranscript(-1 << 20)
	if !strings.Contains(m.viewport.GetContent(), "┃") {
		t.Fatal("recent scroll did not show the inactive auto scrollbar")
	}

	// Start at the top, then press the far end of the track: the grabbed row
	// becomes the thumb's midpoint, exactly like pi-tui scrollbar dragging.
	m.handleTranscriptMouse(click(column, region.Y+region.Height-1))
	if v.top == 0 {
		t.Fatalf("track press did not scroll: top=%d", v.top)
	}
	if !m.document.scrollbar.dragging {
		t.Fatal("track press did not start a scrollbar drag")
	}
	if !strings.Contains(m.viewport.GetContent(), "█") {
		t.Fatal("active scrollbar thumb was not marked while dragging")
	}
	jumped := v.top
	m.handleTranscriptMouse(drag(column, region.Y))
	if v.top >= jumped {
		t.Fatalf("scrollbar drag to top did not move up: %d -> %d", jumped, v.top)
	}
	if _, handled := m.handleTranscriptMouse(release(column, region.Y)); !handled {
		t.Fatal("scrollbar release not handled")
	}
	if m.document.scrollbar.dragging {
		t.Fatal("scrollbar drag survived release")
	}
	if v.top != 0 || v.followEnd {
		t.Fatalf("scrollbar drag to the track top must reach row 0: top=%d follow=%v", v.top, v.followEnd)
	}
}

func TestTranscriptMouseUnhandledCases(t *testing.T) {
	m := interactionModel(t, 40, 12, "plain")
	region := m.transcriptRegion()
	if _, handled := m.handleTranscriptMouse(wheelDown(region.X, region.Y)); handled {
		t.Fatal("wheel belongs to the parent's scroll handler")
	}
	if _, handled := m.handleTranscriptMouse(rightClick(region.X, region.Y)); handled {
		t.Fatal("right button belongs to the terminal")
	}
	if _, handled := m.handleTranscriptMouse(click(region.X, region.Y-1)); handled {
		t.Fatal("press above the transcript region was handled")
	}
	m.modal = "models"
	if _, handled := m.handleTranscriptMouse(click(region.X, region.Y)); handled {
		t.Fatal("press was handled while an overlay owns the screen")
	}
	m.modal = ""
	m.virtualScroll = nil
	if _, handled := m.handleTranscriptMouse(click(region.X, region.Y)); handled {
		t.Fatal("press was handled without a virtual document")
	}
}

// The "newer messages" row is an action, not selectable text: pressing it
// while scrolled up returns to the end of the conversation.
func TestTranscriptNewerMessagesRowJumpsToEnd(t *testing.T) {
	m := newModel()
	m.width, m.height = 60, 12
	m.resize()
	for i := 0; i < 400; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("row %d", i))
	}
	m.refreshTranscript()
	m.scrollTranscript(-1 << 20)
	v := m.virtualScroll
	region := m.transcriptRegion()
	if v.followEnd {
		t.Fatal("scroll to top kept following the end")
	}
	if _, handled := m.handleTranscriptMouse(click(region.X+2, region.Y+region.Height-1)); !handled {
		t.Fatal("newer-messages press not handled")
	}
	if !v.followEnd || v.top != v.totalRows()-v.height {
		t.Fatalf("newer-messages press did not return to the tail: follow=%v top=%d", v.followEnd, v.top)
	}
	if text, ok := m.transcriptSelectionText(); ok {
		t.Fatalf("newer-messages press selected text: %q", text)
	}
}

func TestTranscriptSelectionClearedOnScrollAndSessionReset(t *testing.T) {
	m := interactionModel(t, 40, 12, "abcdef", "ghijkl")
	region := m.transcriptRegion()
	m.handleTranscriptMouse(click(region.X+1, region.Y))
	m.handleTranscriptMouse(drag(region.X+3, region.Y))
	if _, ok := m.transcriptSelectionText(); !ok {
		t.Fatal("selection not started")
	}
	m.scrollTranscript(-5)
	if text, ok := m.transcriptSelectionText(); ok {
		t.Fatalf("scrolling kept a stale character selection: %q", text)
	}
	m.resetVirtualTranscript()
	if m.document.selection.active || strings.Contains(m.viewport.GetContent(), "\x1b[7m") {
		t.Fatal("session reset kept the selection")
	}
}

// Mirrors the JS character-selection cases: a multiline drag copies only the
// selected cells of each row, and a drag that ends on the layout spacer does
// not append blank lines.
func TestMouseSelectionMultilineAndSpacerRows(t *testing.T) {
	m := interactionModel(t, 40, 16, "abcdef\nuvwxyz")
	region := m.transcriptRegion()
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }
	m.handleTranscriptMouse(click(region.X+3, region.Y))
	m.handleTranscriptMouse(drag(region.X+2, region.Y+1))
	m.handleTranscriptMouse(release(region.X+2, region.Y+1))
	if copied != "def\nuvw" {
		t.Fatalf("multiline selection copied %q", copied)
	}

	m.handleTranscriptMouse(click(region.X+2, region.Y))
	m.handleTranscriptMouse(drag(region.X+2, region.Y+2))
	if text, ok := m.transcriptSelectionText(); !ok || text != "cdef\nuvwxyz" {
		t.Fatalf("spacer row leaked into selection: %q ok=%v", text, ok)
	}
	m.handleTranscriptMouse(release(region.X+2, region.Y+2))
	if copied != "cdef\nuvwxyz" {
		t.Fatalf("spacer row leaked into clipboard: %q", copied)
	}
}
