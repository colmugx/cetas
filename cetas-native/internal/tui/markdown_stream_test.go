package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// settleMarkdown behaves like the shell clock: it repaints until the streaming
// block displays the newest source it dispatched. It fails instead of hanging so
// a broken worker is a test failure, not a timeout.
func settleMarkdown(t *testing.T, m *model) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		m.refreshTranscript()
		if markdownSettled(m) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("background Markdown render did not settle (live=%#v)", m.document.live)
		}
		time.Sleep(time.Millisecond)
	}
}

// markdownQueue reads the worker's queue and shutdown flag the way the UI thread
// would, under the pipeline mutex.
func markdownQueue(p *markdownPipeline) (pending, stopped bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pending != nil, p.stopped
}

func markdownSettled(m *model) bool {
	if pipeline := m.document.markdown; pipeline != nil && !pipeline.idle() {
		return false
	}
	cache := m.document.live
	return !cache.valid || cache.renderedRevision == cache.revision
}

// A token burst is coalesced onto one bounded worker: no goroutine and no
// whole-document render per delta, and the settled screen is still the complete
// render of the last source (never a partially merged document).
func TestStreamingMarkdownCoalescesDeltasOnOneWorker(t *testing.T) {
	m := interactionModel(t, 60, 24)
	m.streaming = "**start**\n\n"
	m.refreshTranscript()

	// Dispatch the way the shell does, without repainting between deltas: the
	// worker must merge them instead of laying out one document per token.
	var source strings.Builder
	source.WriteString(m.streaming)
	for i := 0; i < 150; i++ {
		source.WriteString(fmt.Sprintf("token %03d **bold** text\n\n", i))
		m.streaming = source.String()
		m.renderLiveMarkdown(len(m.transcript), m.streaming)
	}
	dispatches := m.document.live.renders
	if dispatches < 100 {
		t.Fatalf("deltas were not dispatched to the worker: %d", dispatches)
	}
	settleMarkdown(t, m)

	pipeline := m.document.markdown
	if pipeline == nil {
		t.Fatal("streaming Markdown never reached the background worker")
	}
	starts, runs, dropped := pipeline.stats()
	if starts != 1 {
		t.Fatalf("started %d Markdown workers for one document", starts)
	}
	if runs >= dispatches {
		t.Fatalf("rendered a document per delta: %d renders for %d sources", runs, dispatches)
	}
	if dropped == 0 {
		t.Fatal("no superseded source was coalesced away")
	}
	want, err := renderMarkdown(m.markdownRenderer, m.streaming)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.mountedTranscriptBlock(len(m.transcript)); got != padTranscriptBlock(want, m.viewport.Width()) {
		t.Fatalf("settled screen is not the full render of the last source:\n got %q\nwant %q", ansi.Strip(got), ansi.Strip(want))
	}
}

// The first frame of a new streaming block has no previous render to keep, so
// it is laid out once synchronously: raw Markdown must never reach the screen.
// Every later frame reads the background result.
func TestFirstStreamingFrameIsRenderedNotRaw(t *testing.T) {
	m := interactionModel(t, 60, 20)
	m.streaming = "**bold** and `code`"
	m.refreshTranscript()
	if plain := ansi.Strip(m.viewport.GetContent()); strings.Contains(plain, "**") || !strings.Contains(plain, "bold") {
		t.Fatalf("first streaming frame is raw Markdown: %q", plain)
	}
	if m.document.live.renders != 1 || m.document.markdown != nil {
		t.Fatalf("first frame should be one synchronous render and no worker: renders=%d worker=%v", m.document.live.renders, m.document.markdown != nil)
	}
}

// A render queued for a previous width must never be painted: the transcript
// keeps the newest layout for the current terminal, at the current width.
func TestStaleMarkdownRenderIsDiscardedOnResize(t *testing.T) {
	m := interactionModel(t, 80, 24)
	m.streaming = "first **paragraph**\n\n" + strings.Repeat("wrap me ", 400)
	m.refreshTranscript()
	m.streaming += "\n\na second paragraph arrives while the frame is queued"
	m.refreshTranscript()
	if m.document.markdown == nil {
		t.Fatal("delta did not reach the background worker")
	}
	queued := m.document.live.revision

	// Resize before the worker can finish: that render belongs to width 80.
	m.width = 40
	m.resize()
	if m.document.live.revision <= queued {
		t.Fatalf("resize did not supersede the queued render: %d -> %d", queued, m.document.live.revision)
	}
	settleMarkdown(t, m)

	want, err := renderMarkdown(m.markdownRenderer, m.streaming)
	if err != nil {
		t.Fatal(err)
	}
	block := m.mountedTranscriptBlock(len(m.transcript))
	if block != padTranscriptBlock(want, m.viewport.Width()) {
		t.Fatalf("screen kept a render from the superseded width:\n got %q\nwant %q", ansi.Strip(block), ansi.Strip(want))
	}
	for _, row := range strings.Split(block, "\n") {
		if width := ansi.StringWidth(row); width != 40 {
			t.Fatalf("row width %d after resize: %q", width, ansi.Strip(row))
		}
	}
}

// Settled history and replay never start the background worker: rendering one
// block once, on the frame that mounts it, is already bounded.
func TestSettledHistoryDoesNotStartMarkdownWorker(t *testing.T) {
	m := interactionModel(t, 80, 24)
	for i := 0; i < 200; i++ {
		m.appendAssistant(fmt.Sprintf("**answer** %d", i))
	}
	m.refreshTranscript()
	if m.document.markdown != nil {
		t.Fatal("settled history started the streaming Markdown worker")
	}
	if len(m.markdownCache) > 100 {
		t.Fatalf("rendered offscreen history: %d", len(m.markdownCache))
	}
}

// A session switch is a new document: the worker belongs to the old transcript
// and a streaming block starts again from its own first frame.
func TestSessionResetDropsMarkdownWorker(t *testing.T) {
	m := interactionModel(t, 60, 24)
	m.streaming = "**start**\n\n" + strings.Repeat("source ", 200)
	m.refreshTranscript()
	m.streaming += "\n\ntail"
	m.renderLiveMarkdown(len(m.transcript), m.streaming)
	if m.document.markdown == nil {
		t.Fatal("delta did not reach the background worker")
	}

	m.resetVirtualTranscript()
	if m.document.markdown != nil {
		t.Fatal("session reset kept the background Markdown worker")
	}
	if m.document.live.valid {
		t.Fatal("session reset kept the previous live render")
	}
	// The next document starts clean: one synchronous first frame, no inherited
	// text from the previous session.
	m.transcript = nil
	m.markdownRaw = nil
	m.streaming = "**fresh**"
	m.refreshTranscript()
	if m.document.live.renders != 1 || m.document.markdown != nil {
		t.Fatalf("new document reused the old worker: renders=%d worker=%v", m.document.live.renders, m.document.markdown != nil)
	}
	if block := m.mountedTranscriptBlock(0); strings.Contains(ansi.Strip(block), "source source") {
		t.Fatalf("new document inherited the previous stream: %q", ansi.Strip(block))
	}
}

func TestSettledMarkdownLeavesTheClockIdle(t *testing.T) {
	m := interactionModel(t, 60, 24)
	m.streaming = "**start**\n\n" + strings.Repeat("source text ", 50)
	m.refreshTranscript()
	m.streaming += "\n\ntail"
	m.refreshTranscript()
	settleMarkdown(t, m)
	if m.markdownRenderPending() {
		t.Fatal("painted render still reported as pending")
	}
	if cmd := m.scheduleUIClock(time.Now()); cmd != nil {
		t.Fatal("settled Markdown kept a frame chain alive")
	}
}
