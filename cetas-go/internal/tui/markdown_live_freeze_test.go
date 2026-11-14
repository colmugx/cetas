package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// freezeStream builds a stream body past the freeze threshold out of
// paragraphs separated by blank lines, optionally ending inside an open fence.
func freezeStream(paragraphs int, openFence bool) string {
	var b strings.Builder
	for i := 0; i < paragraphs; i++ {
		b.WriteString(strings.Repeat("word ", 800))
		b.WriteString("\n\n")
	}
	if openFence {
		b.WriteString("```go\nfunc open() {\n\treturn\n")
	}
	return b.String()
}

func freezeWindowSize() tea.WindowSizeMsg {
	return tea.WindowSizeMsg{Width: 96, Height: 32}
}

// A stream past the freeze threshold stops re-laying-out its whole source on
// every delta: the settled prefix displays as plain text and only a bounded
// tail is rendered as Markdown, with the cut at paragraph boundaries that keep
// code fences balanced.
func TestLiveMarkdownFreezesSettledPrefix(t *testing.T) {
	m := newModel()
	defer m.Close()
	next, _ := m.Update(freezeWindowSize())
	m = next.(model)
	m.markdownRaw = map[int]string{}
	index := len(m.transcript)

	small := freezeStream(3, false)
	if got := m.renderLiveMarkdown(index, small); got == "" {
		t.Fatal("first frame rendered nothing")
	}
	if m.document.live.frozenAt != 0 {
		t.Fatalf("a small stream froze a prefix: %d", m.document.live.frozenAt)
	}

	// Grow past the threshold: the cut lands on a paragraph boundary and the
	// display keeps the plain prefix verbatim.
	grown := freezeStream(8, false)
	m.streaming = grown
	m.renderLiveMarkdown(index, grown)
	settleMarkdown(t, &m)
	got := m.document.live.rendered
	cache := &m.document.live
	if cache.frozenAt == 0 {
		t.Fatal("a heavy stream never froze its prefix")
	}
	if tail := len(grown) - cache.frozenAt; tail > liveTailBytes {
		t.Fatalf("frozen prefix %d leaves a %d-byte tail over the %d bound", cache.frozenAt, tail, liveTailBytes)
	}
	if !strings.HasSuffix(grown[:cache.frozenAt], "\n\n") {
		t.Fatal("the freeze cut is not a paragraph boundary")
	}
	if cache.scanFence {
		t.Fatal("fence parity did not close over a balanced stream")
	}
	if !strings.HasPrefix(got, grown[:min(cache.frozenAt, len(got))]) {
		t.Fatal("the plain frozen prefix is not on screen verbatim")
	}
	if m.document.markdown == nil {
		t.Fatal("heavy stream did not start the render pipeline")
	}
}

// A stream that ends inside an open code fence finds no safe cut past the
// fence: the frozen prefix never advances into it.
func TestLiveMarkdownFreezeRespectsOpenFences(t *testing.T) {
	m := newModel()
	defer m.Close()
	next, _ := m.Update(freezeWindowSize())
	m = next.(model)
	m.markdownRaw = map[int]string{}
	stream := freezeStream(8, true)
	index := len(m.transcript)
	m.streaming = stream
	if got := m.renderLiveMarkdown(index, stream); got == "" {
		t.Fatal("first frame rendered nothing")
	}
	cache := &m.document.live
	if !cache.scanFence {
		t.Fatal("the unclosed fence was not detected")
	}
	if fence := strings.Index(stream, "```go"); cache.frozenAt > fence {
		t.Fatalf("freeze cut %d entered the open fence at %d", cache.frozenAt, fence)
	}
}

// Settling takes the ordinary history path: the raw Markdown source survives
// intact for the full-history layout.
func TestLiveMarkdownSettleRendersFullyAfterFreeze(t *testing.T) {
	m := newModel()
	defer m.Close()
	next, _ := m.Update(freezeWindowSize())
	m = next.(model)
	m.markdownRaw = map[int]string{}
	stream := freezeStream(8, false)
	m.streaming = stream
	index := len(m.transcript)
	m.renderLiveMarkdown(index, stream)
	m.flushAssistant()
	m.streaming = ""
	if got := m.markdownRaw[index]; got != stream {
		t.Fatalf("settled block lost its raw Markdown source: %d bytes", len(got))
	}
}
