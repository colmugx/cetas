package tui

import (
	"fmt"
	"image/color"
	"strings"
	"testing"

	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// windowModel is a 40-column transcript with one long block and a tail block,
// scrolled into the middle of the long one. It is the fixture every seam below
// is asserted on.
func windowModel(t *testing.T) model {
	t.Helper()
	m := *interactionModel(t, 40, 14)
	m.transcript = append(m.transcript, strings.Repeat("line 中文 with a payload that wraps\n", 400))
	m.transcript = append(m.transcript, "tail block")
	m.refreshTranscript()
	m.scrollTranscript(-120)
	// Compare rows only: the auto scrollbar owns the last column for a second
	// after the scroll and is painted by its own seam.
	m.document.scrollbar.hideAt = time.Time{}
	m.refreshTranscript()
	return m
}

// What the viewport paints for a partially mounted block is exactly the same
// rows the whole-block seam reports for it: the window clips a block, it does
// not re-implement its wrapping.
func TestMountedWindowRowsMatchBlockSeam(t *testing.T) {
	m := windowModel(t)
	v := m.virtualScroll
	if v.first != 0 || v.end < 1 || v.end > 2 {
		t.Fatalf("logical block window lost: first=%d end=%d", v.first, v.end)
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "line 中文") {
		t.Fatalf("scrolled window lost its block rows: %q", content)
	}
	want := m.mountedTranscriptRows(0)
	base := v.prefix(0)
	if v.top <= base {
		t.Fatalf("fixture did not scroll inside the block: top=%d base=%d", v.top, base)
	}
	content := strings.Split(m.viewport.GetContent(), "\n")
	offset := m.viewport.YOffset()
	if offset > virtualOverscanRows {
		t.Fatalf("viewport offset %d exceeds the overscan", offset)
	}
	for index, line := range content[offset:] {
		row := v.top + index
		if row >= base+len(want) {
			break
		}
		if line != want[row-base] {
			t.Fatalf("visible row %d differs from the block seam:\n got %q\nwant %q",
				row, ansi.Strip(line), ansi.Strip(want[row-base]))
		}
	}
}

// One wheel event is one mount. The parent defers the reducer's refresh to the
// final layout pass; the transcript reports it through its own counter so a
// second refresh cannot hide behind identical screen contents.
func TestWheelEventIsOneTranscriptRefresh(t *testing.T) {
	m := windowModel(t)
	before := m.virtualScroll.refreshes
	mounts := m.presentation.mounts
	next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
	m = next.(model)
	_ = m.View()
	if got := m.virtualScroll.refreshes - before; got != 1 {
		t.Fatalf("one wheel event refreshed the document %d times", got)
	}
	if got := m.presentation.mounts - mounts; got != 1 {
		t.Fatalf("one wheel event mounted the document %d times", got)
	}
}

// A selection inside a partially mounted block keeps absolute document
// coordinates: the copied cells come from the selected rows, not from the
// mounted slice's own origin.
func TestSelectionInsidePartiallyMountedBlockUsesAbsoluteRows(t *testing.T) {
	m := windowModel(t)
	v := m.virtualScroll
	base := v.prefix(0)
	// Pick a row that is on screen and select its third to sixth cell.
	row := v.top + 1
	region := m.transcriptRegion()
	column := region.X + 2
	if _, handled := m.handleTranscriptMouse(click(column, region.Y+(row-v.top))); !handled {
		t.Fatal("press did not reach the transcript")
	}
	if !m.document.selection.active {
		t.Fatal("press did not start a selection")
	}
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }
	m.handleTranscriptMouse(drag(column+3, region.Y+(row-v.top)))
	self := m.document.selection
	if got, want := self.anchor.row, row; got != want {
		t.Fatalf("selection row %d, want the absolute document row %d", got, want)
	}
	m.handleTranscriptMouse(release(column+3, region.Y+(row-v.top)))
	rows := m.mountedTranscriptRows(0)
	if row-base >= len(rows) {
		t.Fatalf("row %d outside the block (%d rows)", row, len(rows))
	}
	want := strings.TrimRight(ansi.Strip(ansi.Cut(ansi.Strip(rows[row-base]), 2, 6)), " ")
	if copied != want || copied == "" {
		t.Fatalf("copied %q, want the selected cells %q", copied, want)
	}
}

// Resize and palette changes are layout inputs: they must rebuild the block
// rows instead of reusing widths or colours that no longer exist.
func TestWidthAndThemeRebuildCachedRows(t *testing.T) {
	m := windowModel(t)
	v := m.virtualScroll
	builds := v.rows.builds
	m.width = 60
	m.resize()
	if v.rows.builds == builds {
		t.Fatal("a width change reused the previous wrapping")
	}
	builds = v.rows.builds
	m.refreshTranscript()
	if v.rows.builds != builds {
		t.Fatalf("an unchanged frame rebuilt %d layouts", v.rows.builds-builds)
	}
	// A palette change rewraps nothing, but it recolours everything: the
	// identity must not survive it.
	m.surface.fg = color.RGBA{R: 1, G: 2, B: 3, A: 255}
	m.refreshTranscript()
	if v.rows.builds == builds {
		t.Fatal("a palette change reused rows styled for the old colours")
	}
}

// The row cache is per document: a session switch may not hand its rows to the
// next transcript, even when block indices line up.
func TestRowCacheDoesNotCrossSessionSwitch(t *testing.T) {
	m := windowModel(t)
	used := m.virtualScroll.rows.stats().used
	if used == 0 {
		t.Fatal("fixture never populated the row cache")
	}
	m.resetVirtualTranscript()
	if got := m.virtualScroll.rows.stats().used; got != 0 {
		t.Fatalf("session reset kept %d cached bytes", got)
	}
}

// A notice inserted mid-document shifts block indices; the cached rows must be
// released rather than painted for the wrong message.
func TestStructuralInsertDropsCachedRows(t *testing.T) {
	m := windowModel(t)
	if m.virtualScroll.rows.stats().layouts == 0 {
		t.Fatal("fixture never populated the row cache")
	}
	insertVirtualHeights(m.virtualScroll, 1, 1, 3)
	m.reflow()
	if got := m.virtualScroll.rows.stats().layouts; got > 2 {
		t.Fatalf("stale layouts survived a structural insert: %d", got)
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "line 中文") {
		t.Fatalf("document lost its content after an insert: %q", content)
	}
	_ = fmt.Sprint(m.virtualScroll.totalRows())
}
