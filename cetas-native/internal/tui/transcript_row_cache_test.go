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

func giantPlainModel(t *testing.T, lines int) model {
	t.Helper()
	m := *interactionModel(t, 100, 30)
	m.transcript = append(m.transcript, strings.Repeat(
		"fixture line with 中文 and enough text to wrap on a narrower terminal\n", lines))
	m.refreshTranscript()
	return m
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
	if m.markdownCache.stats().entries > 1 {
		t.Fatalf("warm frames retained %d formatted blocks", m.markdownCache.stats().entries)
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
