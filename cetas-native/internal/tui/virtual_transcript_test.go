package tui

import (
	"fmt"
	"strings"
	"testing"
)

// 10k history is a document, not a 10k-item render request. This guard
// enforces the key complexity invariant on every platform.
func TestVirtualTranscriptMountsBoundedWindow(t *testing.T) {
	m := newModel()
	m.width, m.height = 100, 40
	m.resize()
	for i := 0; i < 10000; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("message %d — stable content", i))
	}
	m.refreshTranscript()
	v := m.virtualScroll
	if v == nil || len(v.heights) != 10000 {
		t.Fatalf("logical history was truncated: %#v", v)
	}
	if v.renderedBlocks == 0 || v.renderedBlocks > 70 {
		t.Fatalf("mounted too many blocks at tail: %d", v.renderedBlocks)
	}
	if len(m.viewport.GetContent()) >= 10000 {
		t.Fatalf("viewport mounted the whole transcript: %d bytes", len(m.viewport.GetContent()))
	}
	m.scrollTranscript(-20000)
	if v.renderedBlocks == 0 || v.renderedBlocks > 70 || v.first >= 9000 {
		t.Fatalf("scrolling deep into history was not virtualized: first=%d mounted=%d", v.first, v.renderedBlocks)
	}
	m.scrollTranscript(20000)
	if !v.followEnd || v.end != 10000 {
		t.Fatalf("scroll to tail did not follow current history: end=%d follow=%v", v.end, v.followEnd)
	}
}

func TestVirtualTranscriptFenwickIndex(t *testing.T) {
	v := newVirtualTranscript(30, 8)
	for _, h := range []int{3, 7, 2, 5, 9, 1, 4} {
		v.appendHeight(h)
	}
	want := []int{0, 3, 10, 12, 17, 26, 27, 31}
	for i, expected := range want {
		if got := v.prefix(i); got != expected {
			t.Fatalf("prefix(%d)=%d want %d", i, got, expected)
		}
	}
	for i := 0; i < len(v.heights); i++ {
		if got := v.indexAt(v.prefix(i)); got != i {
			t.Fatalf("indexAt(prefix(%d))=%d", i, got)
		}
	}
	v.setHeight(1, 13)
	if v.prefix(7) != 37 || v.indexAt(9) != 1 {
		t.Fatalf("Fenwick update corrupt: total=%d lookup=%d", v.prefix(7), v.indexAt(9))
	}
}

func TestVirtualTranscriptSearchJumpAndStableResize(t *testing.T) {
	m := newModel()
	m.width, m.height = 50, 25
	m.resize()
	for i := 0; i < 3000; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("entry %04d with text", i))
	}
	m.transcript[2500] = "searchable phrase at row 2500"
	m.refreshTranscript()
	m.findTranscript("searchable phrase")
	v := m.virtualScroll
	if v.top == 0 || v.first < 2400 || v.first > 2500 {
		t.Fatalf("search did not jump to virtual block: top=%d first=%d", v.top, v.first)
	}
	before := v.indexAt(v.top)
	v.followEnd = false
	m.width = 70
	m.resize()
	after := v.indexAt(v.top)
	if before != after {
		t.Fatalf("resize changed anchored message: before=%d after=%d", before, after)
	}
	if len(m.viewport.GetContent()) > 6000 {
		t.Fatalf("resized viewport mounted too much history: %d", len(m.viewport.GetContent()))
	}
}

func TestVirtualTranscriptMarkdownCacheStaysWindowBounded(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 30
	m.resize()
	for i := 0; i < 1500; i++ {
		m.appendAssistant(fmt.Sprintf("**message** %d", i))
	}
	m.refreshTranscript()
	if len(m.markdownCache) > 100 {
		t.Fatalf("rendered offscreen Markdown: %d", len(m.markdownCache))
	}
	m.scrollTranscript(-4000)
	if len(m.markdownCache) > 100 {
		t.Fatalf("offscreen Markdown retained after scroll: %d", len(m.markdownCache))
	}
	if m.virtualScroll.renderedBlocks > 100 {
		t.Fatalf("mounted too many blocks: %d", m.virtualScroll.renderedBlocks)
	}
	if strings.Contains(m.viewport.GetContent(), "message** 1499") {
		t.Fatal("viewport contained an unrelated offscreen source block")
	}
}

func BenchmarkVirtualTranscript10kScroll(b *testing.B) {
	m := newModel()
	m.width, m.height = 100, 38
	m.resize()
	for i := 0; i < 10000; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("history %d", i))
	}
	m.refreshTranscript()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		m.scrollTranscript(-11)
		if m.virtualScroll.top == 0 {
			m.scrollTranscript(1 << 20)
		}
	}
}
