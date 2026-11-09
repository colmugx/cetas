package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// The cached rows must be byte-identical to the rows the terminal would have
// painted before the cache existed: same wrap points (cells, not bytes), same
// padding, same two spacer rows. CJK width and embedded SGR style are the cases
// where a cheaper arithmetic drifts silently.
func TestRowCacheRowsMatchWrappedAndPaddedSource(t *testing.T) {
	text := strings.Join([]string{
		"plain line",
		"",
		"中文 CJK 行 with \x1b[31mred\x1b[0m ansi and a long tail " + strings.Repeat("宽", 20),
		strings.Repeat("x", 180),
		"short 中",
		"tab\tseparated 中 文",
	}, "\n")
	for _, width := range []int{5, 9, 33, 80} {
		layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: width}, text)
		want := wrapTranscriptBlock(padTranscriptBlock(text, width), width)
		for index := range want {
			want[index] = padTranscriptRow(want[index], width)
		}
		spacer := strings.Repeat(" ", width)
		want = append(want, spacer, spacer)
		if layout.height() != len(want) {
			t.Fatalf("width %d: layout height %d, wrap/pad height %d", width, layout.height(), len(want))
		}
		cache := newTranscriptRowCache(1 << 20)
		cache.beginFrame()
		cache.store(layout)
		got := cache.appendRows(nil, layout, 0, layout.height())
		if len(got) != len(want) {
			t.Fatalf("width %d: %d rows, want %d", width, len(got), len(want))
		}
		for index := range want {
			if got[index] != want[index] {
				t.Fatalf("width %d row %d:\n got %q\nwant %q",
					width, index, ansi.Strip(got[index]), ansi.Strip(want[index]))
			}
			// padTranscriptRow fills the row to the width; a wide glyph that
			// straddles the wrap boundary is kept whole, exactly as before.
			if cells := ansi.StringWidth(got[index]); cells < width {
				t.Fatalf("width %d row %d is %d cells: %q", width, index, cells, ansi.Strip(got[index]))
			}
		}
		// A window inside the block is the same rows, read from pages.
		for from := 0; from < len(want); from += 5 {
			to := min(len(want), from+13)
			window := cache.appendRows(nil, layout, from, to)
			if len(window) != to-from {
				t.Fatalf("width %d window [%d,%d) returned %d rows", width, from, to, len(window))
			}
			for index, row := range window {
				if row != want[from+index] {
					t.Fatalf("width %d window row %d drifted:\n got %q\nwant %q",
						width, from+index, ansi.Strip(row), ansi.Strip(want[from+index]))
				}
			}
		}
	}
}

// Search and copy index rows by the layout's own line checkpoints; a blocked
// lookup must resolve the same source line as a linear scan.
func TestRowCacheCheckpointLookupMatchesLinearScan(t *testing.T) {
	var lines []string
	for i := 0; i < 500; i++ {
		lines = append(lines, fmt.Sprintf("line %03d %s", i, strings.Repeat("中", i%7)))
	}
	layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: 17}, strings.Join(lines, "\n"))
	row := 0
	for index, line := range lines {
		gotLine, gotOffset := layout.lineAt(row)
		if gotLine != index || gotOffset != 0 {
			t.Fatalf("row %d resolved to line %d offset %d, want line %d", row, gotLine, gotOffset, index)
		}
		rows := transcriptLineRows(line, 17)
		if again, _ := layout.lineAt(row + rows - 1); again != index {
			t.Fatalf("last row of line %d resolved to %d", index, again)
		}
		row += rows
	}
}

func giantPlainModel(t *testing.T, lines int) model {
	t.Helper()
	m := *interactionModel(t, 100, 30)
	m.transcript = append(m.transcript, strings.Repeat(
		"fixture line with 中文 and enough text to wrap on a narrower terminal\n", lines))
	m.refreshTranscript()
	return m
}

// A block larger than the terminal contributes a viewport-sized row slice, not
// its whole body: plain text and Markdown, cold and warm, follow-end and
// scrolled.
func TestGiantBlockMountsOnlyItsVisibleRows(t *testing.T) {
	for _, kind := range []string{"plain", "markdown"} {
		t.Run(kind, func(t *testing.T) {
			m := *interactionModel(t, 100, 30)
			source := strings.Repeat("fixture paragraph with **bold** and 中文 text\n\n", 600)
			if kind == "plain" {
				m.transcript = append(m.transcript, source)
			} else {
				m.appendAssistant(source)
			}
			m.refreshTranscript()
			v := m.virtualScroll
			if len(v.heights) != 1 {
				t.Fatalf("expected a single block: %v", v.heights)
			}
			if v.heights[0] < 500 {
				t.Fatalf("fixture is not a giant block: %d rows", v.heights[0])
			}
			maxRows := m.viewport.Height() + 2*virtualOverscanRows
			if v.mountedRows > maxRows {
				t.Fatalf("mounted %d rows of a %d-row block for a %d-row viewport",
					v.mountedRows, v.heights[0], m.viewport.Height())
			}
			if limit := maxRows * m.viewport.Width() * 4; len(m.viewport.GetContent()) > limit {
				t.Fatalf("mounted %d bytes for one %d-row block (limit %d)", len(m.viewport.GetContent()), v.heights[0], limit)
			}
			// Leaving the tail scrolls inside the same block without mounting it.
			for step := 0; step < 12; step++ {
				m.scrollTranscript(-40)
				if v.mountedRows > maxRows {
					t.Fatalf("step %d mounted %d rows", step, v.mountedRows)
				}
			}
			if v.first != 0 || v.end != 1 {
				t.Fatalf("logical block window lost: first=%d end=%d", v.first, v.end)
			}
			if m.viewport.YOffset() > virtualOverscanRows {
				t.Fatalf("viewport offset %d exceeds the mounted overscan", m.viewport.YOffset())
			}
		})
	}
}

// A collapsed tool row keeps its bounded summary no matter how much output the
// call produced, and the window still costs one screen of rows.
func TestHugeCollapsedToolMountsABoundedWindow(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	m.applyEvent(event(`{"type":"tool.started","tool_call_id":"big","tool_name":"read","arguments":{"path":"big.txt"}}`))
	result := strings.Repeat("tool output line with 中文 and text\n", 20000)
	m.applyEvent(event(fmt.Sprintf(
		`{"type":"tool.completed","tool_call_id":"big","tool_name":"read","is_error":false,"result":%q}`, result)))
	m.refreshTranscript()

	v := m.virtualScroll
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("collapsed tool mounted %d rows", v.mountedRows)
	}
	content := ansi.Strip(m.viewport.GetContent())
	if !strings.Contains(content, "● read") || !strings.Contains(content, "big.txt") {
		t.Fatalf("collapsed row lost its title: %q", content)
	}
	if strings.Contains(content, "tool output line 19999") {
		t.Fatal("collapsed tool painted its body")
	}
	// The body is still source: it stays searchable without being mounted.
	m.findTranscript("tool output line with 中文 and text")
	if len(m.searchHits) == 0 {
		t.Fatal("collapsed body was not indexed")
	}
	m.clearTranscriptSearch()
}

// Warm frames must not rebuild layouts or rematerialize rows: a clock tick or a
// one-row scroll reads what the previous frame already laid out.
func TestWarmFramesReuseRowsWithoutGrowth(t *testing.T) {
	m := giantPlainModel(t, 4000)
	v := m.virtualScroll
	m.refreshTranscript()
	before := *v.rows
	mounted := v.mountedRows
	for i := 0; i < 25; i++ {
		m.refreshTranscript()
		if v.mountedRows != mounted {
			t.Fatalf("frame %d mounted %d rows, want %d", i, v.mountedRows, mounted)
		}
	}
	if v.rows.builds != before.builds {
		t.Fatalf("warm frame rebuilt layouts: %d -> %d", before.builds, v.rows.builds)
	}
	if v.rows.used != before.used {
		t.Fatalf("warm frame grew the row cache: %d -> %d bytes", before.used, v.rows.used)
	}
	if v.rows.used > transcriptRowCacheBudget {
		t.Fatalf("row cache %d exceeds the %d byte budget", v.rows.used, transcriptRowCacheBudget)
	}
	// The Markdown / formatted-text cache stays window-sized too.
	if len(m.markdownCache) > 1 {
		t.Fatalf("warm frames retained %d formatted blocks", len(m.markdownCache))
	}
}

// Scrolling inside one giant block must stay O(window): no new layout, no
// unbounded cache, and the same bounded mounted row count.
func TestScrollInsideGiantBlockKeepsOneLayout(t *testing.T) {
	m := giantPlainModel(t, 20000)
	v := m.virtualScroll
	builds := v.rows.builds
	pages := v.rows.pages
	for step := 0; step < 40; step++ {
		m.scrollTranscript(-37)
		if v.rows.builds != builds {
			t.Fatalf("step %d re-derived the block layout: %d -> %d", step, builds, v.rows.builds)
		}
		if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
			t.Fatalf("step %d mounted %d rows", step, v.mountedRows)
		}
		if used, budget := v.rows.used, transcriptRowCacheBudget; used > budget {
			t.Fatalf("step %d cache grew to %d bytes over a %d byte budget", step, used, budget)
		}
	}
	if v.rows.pages <= pages {
		t.Fatal("scrolling materialized no new rows")
	}
	if v.top == 0 {
		t.Fatal("fixture did not scroll")
	}
}

// The cache is a byte budget, not a counter: once offscreen history is no
// longer protected, its layouts and pages are released in LRU order.
func TestRowCacheReleasesOffscreenBlocksAtItsByteBudget(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	body := strings.Repeat("history line with 中文 payload 0123456789\n", 700)
	for i := 0; i < 40; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("block %02d\n%s", i, body))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	v.rows.budget = 1 << 20
	for step := 0; step < 45; step++ {
		m.jumpToTranscriptBlock(min(step*3+3, 39))
		if used := v.rows.used; used > v.rows.budget+512<<10 {
			t.Fatalf("step %d: cache holds %d bytes over a %d byte budget", step, used, v.rows.budget)
		}
	}
	if v.rows.evictions == 0 {
		t.Fatalf("no layout was released: used=%d budget=%d", v.rows.used, v.rows.budget)
	}
	if len(v.rows.byBlock) > transcriptRowCacheEntries {
		t.Fatalf("%d cached layouts over the entry cap %d", len(v.rows.byBlock), transcriptRowCacheEntries)
	}
	// A block that scrolled back in is rebuilt from source, never painted empty.
	m.jumpToTranscriptBlock(0)
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "block 00") {
		t.Fatalf("revisited block was not rebuilt: %q", content)
	}
}

// A tool event invalidates exactly the edited block: its rows are rebuilt and
// the new result is painted, while the mount path stays bounded.
func TestToolRevisionRebuildsExactlyOneBlock(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	m.transcript = append(m.transcript, "context above")
	m.refreshTranscript()
	m.applyEvent(event(`{"type":"tool.started","tool_call_id":"c1","tool_name":"read","arguments":{"path":"a.go"}}`))
	m.refreshTranscript()
	builds := m.virtualScroll.rows.builds
	revision := m.virtualScroll.revisionAt(1)

	m.applyEvent(event(`{"type":"tool.completed","tool_call_id":"c1","tool_name":"read","is_error":false,"result":"fresh result body"}`))
	m.refreshTranscript()
	if got := m.virtualScroll.revisionAt(1); got == revision {
		t.Fatal("tool completion did not bump the block revision")
	}
	if got := m.virtualScroll.rows.builds; got != builds+1 {
		t.Fatalf("rebuild count %d, want %d (one edited block)", got, builds+1)
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "fresh result body") {
		t.Fatalf("stale rows survived the tool completion: %q", content)
	}
}

// Appending a block and invalidating it before the next sync (the streaming
// tool pattern) must not flush the cached rows of the window the user reads.
func TestAppendThenInvalidateKeepsTheCachedWindow(t *testing.T) {
	m := giantPlainModel(t, 4000)
	v := m.virtualScroll
	builds := v.rows.builds
	// A new tool block is appended and invalidated before any refresh runs.
	at := len(m.transcript)
	m.transcript = append(m.transcript, "• read ✓")
	m.invalidateTranscriptBlock(at)
	if len(v.revisions) <= len(v.heights) {
		t.Fatalf("fixture did not bump ahead of the index: revisions=%d heights=%d", len(v.revisions), len(v.heights))
	}
	m.refreshTranscript()
	if len(v.rows.byBlock) == 0 {
		t.Fatal("append+invalidate flushed the row cache")
	}
	// Only the new block is derived: the giant block in the window is reused.
	if got := v.rows.builds; got != builds+1 {
		t.Fatalf("append+invalidate built %d layouts, want %d (the new block only)", got-builds, 1)
	}
	layout, ok := v.rows.byBlock[at]
	if !ok || len(layout.lines) == 0 || !strings.Contains(layout.lines[0], "read") {
		t.Fatalf("the appended block was not laid out from its source: %#v", layout)
	}
}

// Expansion is a layout input, not a scroll: toggling ctrl+o/ctrl+t must not
// reuse the previous shape, and toggling back must reuse the old one.
func TestExpansionFlagsPartitionTheRowCache(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	m.applyEvent(event(`{"type":"tool.started","tool_call_id":"c1","tool_name":"read","arguments":{"path":"a.go"}}`))
	m.applyEvent(event(fmt.Sprintf(
		`{"type":"tool.completed","tool_call_id":"c1","tool_name":"read","is_error":false,"result":%q}`,
		strings.Repeat("read line\n", 40))))
	m.refreshTranscript()
	collapsed := m.viewport.GetContent()

	m.showTools = true
	m.refreshTranscript()
	expanded := m.viewport.GetContent()
	if collapsed == expanded {
		t.Fatal("ctrl+o reused the collapsed rows")
	}
	if ansi.StringWidth(ansi.Strip(expanded)) == 0 || !strings.Contains(ansi.Strip(expanded), "read line") {
		t.Fatalf("expanded rows lost the tool body: %q", ansi.Strip(expanded))
	}
	m.showTools = false
	m.refreshTranscript()
	if again := m.viewport.GetContent(); again != collapsed {
		t.Fatal("collapsing again did not reproduce the collapsed rows")
	}
}

// A still-streaming answer is a live block: it must mount one screen of rows,
// keep them across frames that carry no delta, and rebuild exactly once when a
// delta is dispatched and its render settles.
func TestGiantStreamingBlockMountsBoundedRows(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	m.streaming = strings.Repeat("streamed **paragraph** with 中文 and words\n\n", 800)
	m.refreshTranscript()
	v := m.virtualScroll
	live := len(m.transcript)
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("streaming block mounted %d rows", v.mountedRows)
	}
	if _, ok := v.rows.byBlock[live]; !ok {
		t.Fatal("the live block has no cached layout")
	}
	builds, renders := v.rows.builds, m.document.live.renders
	for i := 0; i < 10; i++ {
		m.refreshTranscript()
	}
	if v.rows.builds != builds || m.document.live.renders != renders {
		t.Fatalf("idle frames rebuilt the streaming block: builds %d->%d renders %d->%d",
			builds, v.rows.builds, renders, m.document.live.renders)
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("idle frames mounted %d rows", v.mountedRows)
	}

	m.streaming += "\n\ntail paragraph 中文"
	m.refreshTranscript()
	if m.document.live.renders != renders+1 {
		t.Fatalf("delta was not dispatched: %d renders", m.document.live.renders-renders)
	}
	settleMarkdown(t, &m)
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("settled frame mounted %d rows", v.mountedRows)
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "tail paragraph") {
		t.Fatalf("settled frame did not paint the newest render: %q", content)
	}
	if v.rows.builds > builds+3 {
		t.Fatalf("one delta rebuilt the layout %d times", v.rows.builds-builds)
	}
}

// At the very top of the document there is no overscan above, so the painted
// row 0 is document row 0 and the viewport needs no scroll offset.
func TestWindowAtDocumentTopStartsAtTheFirstRow(t *testing.T) {
	m := *interactionModel(t, 60, 12)
	m.welcomeHidden = true
	m.reflow()
	for i := 0; i < 300; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("line 中文 payload %d", i))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	m.scrollTranscript(-1 << 20)
	if v.top != 0 || v.first != 0 {
		t.Fatalf("scroll to top: top=%d first=%d", v.top, v.first)
	}
	if offset := m.viewport.YOffset(); offset != 0 {
		t.Fatalf("top of document has offset %d, want 0", offset)
	}
	rows := strings.Split(m.viewport.GetContent(), "\n")
	if !strings.Contains(ansi.Strip(rows[0]), "line 中文 payload 0") {
		t.Fatalf("first painted row is not the first document row: %q", ansi.Strip(rows[0]))
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("top window mounted %d rows", v.mountedRows)
	}
	if v.end >= len(v.heights) {
		t.Fatalf("top window reached the end of a %d-block document: end=%d", len(v.heights), v.end)
	}
	if another := strings.Split(m.viewport.GetContent(), "\n"); strings.Contains(ansi.Strip(strings.Join(another, "\n")), "line 中文 payload 299") {
		t.Fatal("top window painted offscreen history")
	}
}

// A paged-replay insertion grows the height index without bumping any
// revision; block indices moved, so no cached row may be painted for them.
func TestPagedInsertInvalidatesRowCache(t *testing.T) {
	m := giantPlainModel(t, 2000)
	v := m.virtualScroll
	builds := v.rows.builds
	if len(v.rows.byBlock) == 0 {
		t.Fatal("fixture did not cache a layout")
	}
	m.insertPagedPlaceholders(1, 2)
	if len(v.revisions) >= len(v.heights) {
		t.Fatalf("fixture did not desync the index: revisions=%d heights=%d", len(v.revisions), len(v.heights))
	}
	m.refreshTranscript()
	if v.rows.builds <= builds {
		t.Fatal("structural insert reused the pre-insert rows")
	}
	// The shifted document still paints: the giant block is block 3 now.
	m.jumpToTranscriptBlock(3)
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "fixture line with 中文") {
		t.Fatalf("shifted document painted nothing: %q", content)
	}
}

// A rebuilt block can shrink: the document length drops, the scroll position is
// clamped, and the old rows must not survive as a stale suffix.
func TestRebuiltBlockShrinksWithoutStaleRows(t *testing.T) {
	m := giantPlainModel(t, 2000)
	v := m.virtualScroll
	m.jumpToTranscriptBlock(0)
	before := v.heights[0]
	if before < 500 {
		t.Fatalf("fixture is not a giant block: %d rows", before)
	}
	// The paged owner replaces a body with the authoritative shorter text.
	m.transcript[0] = "short replacement"
	m.invalidateTranscriptBlock(0)
	m.refreshTranscript()

	if v.heights[0] != 3 {
		t.Fatalf("rebuilt block height %d, want 3", v.heights[0])
	}
	content := ansi.Strip(m.viewport.GetContent())
	if !strings.Contains(content, "short replacement") {
		t.Fatalf("rebuilt block was not painted: %q", content)
	}
	if strings.Contains(content, "fixture line with 中文") {
		t.Fatal("stale rows survived the shrink")
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("shrunken document mounted %d rows", v.mountedRows)
	}
	layout, ok := v.rows.byBlock[0]
	if !ok || len(layout.lines) != 1 || layout.height() != 3 {
		t.Fatalf("cached layout does not describe the new body: %#v", layout)
	}
}

// Settling a stream hands the live block to the transcript: the same index now
// has a different identity, so the live rows must be rebuilt, not reused.
func TestSettledStreamRebuildsUnderTheSettledIdentity(t *testing.T) {
	m := *interactionModel(t, 80, 24)
	m.streaming = strings.Repeat("streamed **paragraph** 中文\n\n", 200)
	m.refreshTranscript()
	v := m.virtualScroll
	live := v.rows.byBlock[0]
	if live == nil || live.id.revision == 0 {
		t.Fatalf("live block was never laid out: %#v", live)
	}
	builds := v.rows.builds

	m.flushAssistant()
	m.streaming = ""
	m.refreshTranscript()

	settled := v.rows.byBlock[0]
	if settled == nil {
		t.Fatal("settled block is not cached")
	}
	if settled == live || settled.id.revision != 0 {
		t.Fatalf("live rows were reused for the settled block: %#v", settled.id)
	}
	if v.rows.builds != builds+1 {
		t.Fatalf("settle built %d layouts, want 1", v.rows.builds-builds)
	}
	if v.heights[0] != settled.height() {
		t.Fatalf("measured height %d does not match the layout %d", v.heights[0], settled.height())
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("settled document mounted %d rows", v.mountedRows)
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "streamed") {
		t.Fatalf("settled block was not painted: %q", content)
	}
}

// A block whose own line index exceeds a quarter of the budget is retained only
// while it is painted: it is released when it scrolls away instead of holding
// the cache for the rest of the session, and rebuilt from source when it
// scrolls back.
func TestOversizedBlockIsReleasedWhenItLeavesTheWindow(t *testing.T) {
	m := *interactionModel(t, 100, 30)
	giant := strings.Repeat("oversized payload line with 中文 text 0123456789 abcdefgh\n", 30000)
	m.transcript = append(m.transcript, giant)
	for i := 0; i < 40; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("filler %02d", i))
	}
	m.refreshTranscript()
	v := m.virtualScroll

	m.jumpToTranscriptBlock(0)
	layout, ok := v.rows.byBlock[0]
	if !ok {
		t.Fatal("painted giant block has no layout")
	}
	if !layout.oversize {
		t.Fatalf("fixture is not past the oversized threshold: %d bytes", layout.bytes)
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("giant block mounted %d rows", v.mountedRows)
	}
	builds := v.rows.builds

	m.jumpToTranscriptBlock(len(m.transcript) - 1)
	if _, held := v.rows.byBlock[0]; held {
		t.Fatal("oversized layout was retained after it scrolled away")
	}
	if v.rows.used > v.rows.budget {
		t.Fatalf("cache holds %d bytes over its %d byte budget", v.rows.used, v.rows.budget)
	}

	m.jumpToTranscriptBlock(0)
	if v.rows.builds <= builds {
		t.Fatal("oversized block was not re-derived after scrolling back")
	}
	if content := ansi.Strip(m.viewport.GetContent()); !strings.Contains(content, "oversized payload line") {
		t.Fatalf("revisited oversized block painted nothing: %q", content)
	}
	if v.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("revisited oversized block mounted %d rows", v.mountedRows)
	}
}

// The reducer seam: one wheel event is one presentation pass, and that pass
// paints a bounded window even inside a giant block.
func TestWheelEventOnGiantBlockMountsOneBoundedWindow(t *testing.T) {
	m := giantPlainModel(t, 4000)
	m.scrollTranscript(-100)
	before := m.presentation.mounts
	refreshes := m.virtualScroll.refreshes
	mounted := m.virtualScroll.mountedRows

	next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
	m = next.(model)
	_ = m.View()

	if got := m.presentation.mounts - before; got != 1 {
		t.Fatalf("wheel event mounted the document %d times, want once", got)
	}
	// The mount counter and the virtual document agree on the same frame: one
	// reducer event is one row window, independent of View.
	if got := m.virtualScroll.refreshes - refreshes; got != 1 {
		t.Fatalf("wheel event refreshed the virtual transcript %d times, want once", got)
	}
	if m.virtualScroll.mountedRows > m.viewport.Height()+2*virtualOverscanRows {
		t.Fatalf("wheel event mounted %d rows", m.virtualScroll.mountedRows)
	}
	if m.virtualScroll.mountedRows != mounted {
		t.Fatalf("a three-row scroll changed the mounted row count: %d -> %d", mounted, m.virtualScroll.mountedRows)
	}
}

// A window that starts inside a block must still fill the viewport with its
// overscan on both sides, and the viewport offset must stay inside that
// overscan: the mounted slice begins at the window row, not at the block row.
func TestScrolledWindowFillsViewportAroundTheAnchor(t *testing.T) {
	m := *interactionModel(t, 80, 40)
	m.welcomeHidden = true
	m.reflow()
	for i := 0; i < 3000; i++ {
		m.appendAssistant(fmt.Sprintf("**message** %d\n\nsecond paragraph %d with a longer body that wraps at eighty columns", i, i))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	if v.mountedRows < m.viewport.Height() {
		t.Fatalf("cold tail mounted %d rows for a %d-row viewport", v.mountedRows, m.viewport.Height())
	}
	m.scrollTranscript(-3000)
	v = m.virtualScroll
	if want := m.viewport.Height() + 2*virtualOverscanRows; v.mountedRows != want {
		t.Fatalf("scrolled window mounted %d rows, want %d", v.mountedRows, want)
	}
	if offset := m.viewport.YOffset(); offset != virtualOverscanRows {
		t.Fatalf("viewport offset %d, want %d", offset, virtualOverscanRows)
	}
	if v.first >= v.end || v.end > len(v.heights) {
		t.Fatalf("logical block window is inconsistent: first=%d end=%d blocks=%d", v.first, v.end, len(v.heights))
	}
	// A round trip returns to the same block window and row count; the auto
	// scrollbar is painted by its own seam and is not part of this comparison.
	first, end, mounted := v.first, v.end, v.mountedRows
	m.scrollTranscript(200)
	m.scrollTranscript(-200)
	if v.first != first || v.end != end || v.mountedRows != mounted {
		t.Fatalf("round trip changed the window: first %d->%d end %d->%d rows %d->%d",
			first, v.first, end, v.end, mounted, v.mountedRows)
	}
}

func wheelFrameModel(b *testing.B, kind string) model {
	b.Helper()
	m := newModel()
	m.width, m.height = 108, 36
	m.welcomeHidden = true
	m.resize()
	switch kind {
	case "tiny_10k":
		for i := 0; i < 10000; i++ {
			m.transcript = append(m.transcript, fmt.Sprintf("history %d", i))
		}
	case "giant_plain":
		m.transcript = append(m.transcript, strings.Repeat(
			"source line with 中文 and enough text to wrap across narrower terminals\n", 2048))
	case "giant_markdown":
		m.appendAssistant(strings.Repeat("paragraph with **bold** and `code` and 中文.\n\n", 1024))
	case "huge_collapsed_tool":
		m.applyEvent(event(`{"type":"tool.started","tool_call_id":"large-read","tool_name":"read","arguments":{"path":"large.txt"}}`))
		m.applyEvent(event(fmt.Sprintf(
			`{"type":"tool.completed","tool_call_id":"large-read","tool_name":"read","is_error":false,"result":%q}`,
			strings.Repeat("tool output line with 中文 and text\n", 16384))))
	}
	m.refreshTranscript()
	m.scrollTranscript(-100)
	return m
}

// The complete input path a user feels: wheel message through the reducer, the
// presentation pass and View. Long bodies and the old tiny-message history are
// measured by the same loop so the row window can be compared honestly.
func BenchmarkWheelUpdateViewFrame(b *testing.B) {
	for _, kind := range []string{"tiny_10k", "giant_plain", "giant_markdown", "huge_collapsed_tool"} {
		b.Run(kind, func(b *testing.B) {
			m := wheelFrameModel(b, kind)
			defer m.Close()
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
				m = next.(model)
				_ = m.View()
				if m.virtualScroll.top == 0 {
					m.scrollTranscript(1 << 25)
					m.scrollTranscript(-100)
				}
			}
			b.StopTimer()
			b.ReportMetric(float64(m.virtualScroll.mountedRows), "mounted_rows")
			b.ReportMetric(float64(len(m.viewport.GetContent())), "content_bytes")
		})
	}
}

// The mount pass alone, without the frame chrome: this is the work the row
// cache exists to remove. Every fixture mounts the same one-screen window.
func BenchmarkTranscriptRefreshWindow(b *testing.B) {
	for _, kind := range []string{"tiny_10k", "giant_plain", "giant_markdown", "huge_collapsed_tool"} {
		b.Run(kind, func(b *testing.B) {
			m := wheelFrameModel(b, kind)
			defer m.Close()
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				m.refreshTranscript()
			}
			b.StopTimer()
			b.ReportMetric(float64(m.virtualScroll.mountedRows), "mounted_rows")
			b.ReportMetric(float64(m.virtualScroll.rows.used), "cache_bytes")
		})
	}
}
