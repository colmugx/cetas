package tui

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"charm.land/glamour/v2"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// historyRenderGate is the injectable seam for cold settled Markdown. The
// production render is replaced with it so a test can hold glamour in flight,
// prove that neither Update nor the mount pass waits for it, and then release
// exactly the render it wants to settle.
type historyRenderGate struct {
	release  chan struct{}
	entered  chan string
	finished chan string
	stop     chan struct{}

	mu       sync.Mutex
	sources  []string
	timedOut bool
}

func installHistoryRenderGate(t *testing.T) *historyRenderGate {
	t.Helper()
	gate := &historyRenderGate{
		release:  make(chan struct{}, 64),
		entered:  make(chan string, 64),
		finished: make(chan string, 64),
		stop:     make(chan struct{}),
	}
	historyMarkdownSeamMu.Lock()
	previousNew, previousRender := historyMarkdownNewRenderer, historyMarkdownRender
	historyMarkdownNewRenderer = func(int, ui.Theme) (*glamour.TermRenderer, error) { return nil, nil }
	historyMarkdownRender = gate.render
	historyMarkdownSeamMu.Unlock()
	t.Cleanup(func() {
		// Unblock anything still held, then put the production seams back. The
		// seam mutex orders this swap against a worker that already read the
		// function value, so restoring them never races a goroutine.
		close(gate.stop)
		historyMarkdownSeamMu.Lock()
		historyMarkdownNewRenderer, historyMarkdownRender = previousNew, previousRender
		historyMarkdownSeamMu.Unlock()
	})
	return gate
}

func (g *historyRenderGate) render(_ *glamour.TermRenderer, source string) (string, error) {
	g.mu.Lock()
	g.sources = append(g.sources, source)
	g.mu.Unlock()
	select {
	case g.entered <- source:
	default:
	}
	select {
	case <-g.release:
	case <-g.stop:
	case <-time.After(3 * time.Second):
		// A synchronous caller on the test goroutine would land here. The case
		// fails on the elapsed-time assertion instead of hanging the suite.
		g.mu.Lock()
		g.timedOut = true
		g.mu.Unlock()
	}
	rendered := historyRenderedMarker(len(source))
	select {
	case g.finished <- rendered:
	default:
	}
	return rendered, nil
}

func (g *historyRenderGate) calls() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.sources)
}

func (g *historyRenderGate) expired() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.timedOut
}

func (g *historyRenderGate) allow() { g.release <- struct{}{} }

func (g *historyRenderGate) nextEntered(t *testing.T) string {
	t.Helper()
	select {
	case source := <-g.entered:
		return source
	case <-time.After(5 * time.Second):
		t.Fatal("no cold Markdown render started")
		return ""
	}
}

func (g *historyRenderGate) nextFinished(t *testing.T) string {
	t.Helper()
	select {
	case rendered := <-g.finished:
		return rendered
	case <-time.After(5 * time.Second):
		t.Fatal("no cold Markdown render finished")
		return ""
	}
}

// historyRenderedMarker is what the gate's render produces: a bounded, visible
// proof that the finished layout (not the plain fallback) reached the screen.
func historyRenderedMarker(size int) string {
	return fmt.Sprintf("cold-rendered %d bytes", size)
}

// giantHistoryMarkdown is a settled source above the synchronous threshold.
func giantHistoryMarkdown(multiple int) string {
	line := "paragraph with **bold** and `code` and 中文 text\n\n"
	return strings.Repeat(line, (historyMarkdownSyncLimit*multiple)/len(line)+1)
}

// settleHistoryMarkdown repaints until the cold worker has nothing queued,
// running or unpainted, the way the shell clock will once the parent wires the
// pending predicate. It fails instead of hanging so a broken worker is a test
// failure, not a timeout.
func settleHistoryMarkdown(t *testing.T, m *model) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		m.refreshTranscript()
		if !m.historyMarkdownPending() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("cold Markdown render did not settle")
		}
		time.Sleep(time.Millisecond)
	}
}

func historyQueueLength(w *historyMarkdownWorker) int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.queue)
}

func historyResultCount(w *historyMarkdownWorker) int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.results)
}

func historyRunning(w *historyMarkdownWorker) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.running
}

func historyStopped(w *historyMarkdownWorker) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.stopped
}

func waitForHistory(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("%s did not happen", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// A giant cold settled block must never be laid out on the frame that mounts
// it: the mount paints its truthful plain source, the document worker renders
// in the background, and the finished layout replaces the fallback rows and
// height on a later frame.
func TestGiantColdMarkdownRendersOffTheUpdatePath(t *testing.T) {
	gate := installHistoryRenderGate(t)
	m := interactionModel(t, 80, 24)
	defer m.closeHistoryMarkdown()
	source := giantHistoryMarkdown(3)
	m.appendAssistant(source)

	start := time.Now()
	m.refreshTranscript()
	if elapsed := time.Since(start); elapsed > time.Second || gate.expired() {
		t.Fatalf("cold mount waited %v for a Markdown layout", elapsed)
	}
	if gate.calls() != 1 {
		t.Fatalf("cold block dispatched %d renders, want one", gate.calls())
	}
	if len(m.markdownCache) != 0 {
		t.Fatalf("cold mount rendered %d blocks synchronously", len(m.markdownCache))
	}
	if !m.historyMarkdownPending() {
		t.Fatal("cold render was not reported as pending")
	}
	plain := ansi.Strip(m.viewport.GetContent())
	if !strings.Contains(plain, "paragraph with **bold**") {
		t.Fatalf("pending block did not paint its truthful source: %q", plain)
	}
	if strings.Contains(plain, "cold-rendered") {
		t.Fatal("painted a render that had not finished")
	}
	estimate := m.virtualScroll.heights[0]

	// Frames and scrolls while the render is in flight neither block nor
	// dispatch the same block twice.
	m.scrollTranscript(-3)
	m.refreshTranscript()
	if gate.calls() != 1 {
		t.Fatalf("pending cold render was dispatched again: %d renders", gate.calls())
	}

	gate.allow()
	if rendered := gate.nextFinished(t); rendered != historyRenderedMarker(len(source)) {
		t.Fatalf("worker rendered %q", rendered)
	}
	settleHistoryMarkdown(t, m)

	if got, want := m.markdownCache[0], historyRenderedMarker(len(source)); got != want {
		t.Fatalf("applied render %q, want %q", got, want)
	}
	plain = ansi.Strip(m.viewport.GetContent())
	if !strings.Contains(plain, "cold-rendered") || strings.Contains(plain, "**bold**") {
		t.Fatalf("finished layout did not replace the fallback: %q", plain)
	}
	if got := m.virtualScroll.heights[0]; got >= estimate {
		t.Fatalf("applied render did not remeasure the block: %d -> %d rows", estimate, got)
	}
	if m.historyMarkdownPending() {
		t.Fatal("painted cold render still reported as pending")
	}

	// Warm frames read the applied render: no second layout, no second render.
	builds := m.virtualScroll.rows.builds
	for i := 0; i < 5; i++ {
		m.refreshTranscript()
	}
	if gate.calls() != 1 {
		t.Fatalf("warm frames re-rendered the block: %d renders", gate.calls())
	}
	if m.virtualScroll.rows.builds != builds {
		t.Fatalf("warm frames re-derived the applied layout: %d -> %d", builds, m.virtualScroll.rows.builds)
	}
}

// A render queued for a previous width must never be painted: the block keeps
// waiting for the layout of the terminal the user is actually looking at.
func TestGiantColdMarkdownDiscardsResultFromSupersededWidth(t *testing.T) {
	gate := installHistoryRenderGate(t)
	m := interactionModel(t, 80, 24)
	defer m.closeHistoryMarkdown()
	source := giantHistoryMarkdown(2)
	m.appendAssistant(source)
	m.refreshTranscript()
	gate.nextEntered(t)

	m.width = 60
	m.resize()
	if queued := historyQueueLength(m.virtualScroll.history); queued != 1 {
		t.Fatalf("resize queued %d cold renders, want the new width", queued)
	}
	gate.allow()
	gate.nextFinished(t)
	// The worker stores the result just after the render returns; wait for the
	// frame that will validate it, not for a goroutine schedule.
	waitForHistory(t, "superseded-width render", func() bool {
		return historyResultCount(m.virtualScroll.history) == 1
	})
	m.refreshTranscript()
	if len(m.markdownCache) != 0 {
		t.Fatal("painted a render from the superseded width")
	}
	if strings.Contains(ansi.Strip(m.viewport.GetContent()), "cold-rendered") {
		t.Fatal("superseded-width render reached the screen")
	}

	if entered := gate.nextEntered(t); entered != source {
		t.Fatalf("worker rendered the wrong source: %d bytes", len(entered))
	}
	gate.allow()
	gate.nextFinished(t)
	settleHistoryMarkdown(t, m)
	if got, want := m.markdownCache[0], historyRenderedMarker(len(source)); got != want {
		t.Fatalf("applied render %q, want %q", got, want)
	}
	if _, runs, _ := m.virtualScroll.history.stats(); runs != 2 {
		t.Fatalf("worker performed %d layouts, want one per width", runs)
	}
}

// A block edited while its cold render is in flight keeps the new source: the
// stale layout is discarded and the new one is queued.
func TestGiantColdMarkdownDiscardsResultFromSupersededSource(t *testing.T) {
	gate := installHistoryRenderGate(t)
	m := interactionModel(t, 80, 24)
	defer m.closeHistoryMarkdown()
	m.appendAssistant(giantHistoryMarkdown(2))
	m.refreshTranscript()
	gate.nextEntered(t)

	edited := giantHistoryMarkdown(1) + "replaced **source**\n\n"
	m.transcript[0] = edited
	m.invalidateTranscriptBlock(0)
	gate.allow()
	gate.nextFinished(t)
	waitForHistory(t, "superseded-source render", func() bool {
		return historyResultCount(m.virtualScroll.history) == 1
	})
	m.refreshTranscript()
	if len(m.markdownCache) != 0 {
		t.Fatal("painted a render of the superseded source")
	}
	if strings.Contains(ansi.Strip(m.viewport.GetContent()), "cold-rendered") {
		t.Fatal("superseded-source render reached the screen")
	}

	if entered := gate.nextEntered(t); entered != edited {
		t.Fatalf("worker did not queue the edited source: %d bytes, want %d", len(entered), len(edited))
	}
	gate.allow()
	gate.nextFinished(t)
	settleHistoryMarkdown(t, m)
	if got, want := m.markdownCache[0], historyRenderedMarker(len(edited)); got != want {
		t.Fatalf("applied render %q, want the edited source %q", got, want)
	}
}

// A session switch is a new document: the cold worker is stopped, an in-flight
// completion is dropped, and the next document starts without inheriting it.
func TestGiantColdMarkdownDroppedOnSessionReset(t *testing.T) {
	gate := installHistoryRenderGate(t)
	m := interactionModel(t, 80, 24)
	defer m.closeHistoryMarkdown()
	m.appendAssistant(giantHistoryMarkdown(2))
	m.refreshTranscript()
	gate.nextEntered(t)
	worker := m.virtualScroll.history
	if worker == nil {
		t.Fatal("cold block did not start the document worker")
	}

	m.resetVirtualTranscript()
	if m.virtualScroll.history != nil {
		t.Fatal("session reset kept the cold Markdown worker")
	}
	if !historyStopped(worker) {
		t.Fatal("session reset left the old worker open")
	}
	gate.allow()
	gate.nextFinished(t)
	waitForHistory(t, "old cold worker exit", func() bool { return !historyRunning(worker) })

	// The next document starts clean and never inherits the previous render.
	m.transcript = []string{"**fresh** settled answer"}
	m.markdownRaw = map[int]string{0: "**fresh** settled answer"}
	m.refreshTranscript()
	if m.historyMarkdownPending() {
		t.Fatal("new document inherited the previous cold render")
	}
	if strings.Contains(ansi.Strip(m.viewport.GetContent()), "cold-rendered") {
		t.Fatal("new document painted the previous document's render")
	}
}

// The queue and the retained results are bounded: a fast scroll through history
// must not turn into an unbounded backlog or an unbounded frame hand-off.
func TestHistoryMarkdownWorkerQueueAndResultsAreBounded(t *testing.T) {
	gate := installHistoryRenderGate(t)
	w := newHistoryMarkdownWorker(historyMarkdownQueueDepth)
	defer w.stop()

	for i := 0; i < 100; i++ {
		w.submit(historyMarkdownJob{
			index:  i,
			key:    historyMarkdownKey{revision: 1, width: 80},
			source: fmt.Sprintf("block %d", i),
		})
	}
	if entered := gate.nextEntered(t); entered == "" {
		t.Fatal("the single worker never started a cold render")
	}
	if queued := historyQueueLength(w); queued > historyMarkdownQueueDepth {
		t.Fatalf("queue holds %d jobs over the %d bound", queued, historyMarkdownQueueDepth)
	}
	if _, _, dropped := w.stats(); dropped == 0 {
		t.Fatal("the bound refused nothing")
	}
	// The same pending job is not queued twice.
	before := historyQueueLength(w)
	w.submit(historyMarkdownJob{index: 99, key: historyMarkdownKey{revision: 1, width: 80}, source: "block 99"})
	w.submit(historyMarkdownJob{index: 99, key: historyMarkdownKey{revision: 1, width: 80}, source: "block 99"})
	if after := historyQueueLength(w); after > before {
		t.Fatalf("an unchanged block grew the queue: %d -> %d", before, after)
	}

	for i := 0; i < historyMarkdownResultLimit*3; i++ {
		w.finish(historyMarkdownResult{index: i, key: historyMarkdownKey{revision: 1, width: 80}, rendered: "x"})
	}
	if retained := historyResultCount(w); retained > historyMarkdownResultLimit {
		t.Fatalf("retained %d results over the %d bound", retained, historyMarkdownResultLimit)
	}
	taken := 0
	for {
		if _, ok := w.take(); !ok {
			break
		}
		taken++
	}
	if taken > historyMarkdownResultLimit {
		t.Fatalf("handed the UI %d results over the %d bound", taken, historyMarkdownResultLimit)
	}
	// The worker is still parked inside the gate's render; the test's deferred
	// stop and the gate cleanup release it. No further job may be dispatched.
	if gate.calls() != 1 {
		t.Fatalf("one worker performed %d layouts for a bounded queue", gate.calls())
	}
}

// An idle document releases its worker instead of parking a goroutine for the
// life of the process; the next giant block starts it again.
func TestHistoryMarkdownWorkerExitsWhenIdleAndRestarts(t *testing.T) {
	gate := installHistoryRenderGate(t)
	w := newHistoryMarkdownWorker(2)
	w.idleExit = 5 * time.Millisecond
	defer w.stop()

	w.submit(historyMarkdownJob{index: 0, key: historyMarkdownKey{revision: 1, width: 80}, source: "first"})
	gate.nextEntered(t)
	gate.allow()
	gate.nextFinished(t)
	waitForHistory(t, "idle worker exit", func() bool { return !historyRunning(w) })
	if _, ok := w.take(); !ok {
		t.Fatal("the finished render was not retained")
	}
	if !w.idle() {
		t.Fatal("an idle, drained worker still reports work")
	}

	w.submit(historyMarkdownJob{index: 1, key: historyMarkdownKey{revision: 1, width: 80}, source: "second"})
	gate.nextEntered(t)
	gate.allow()
	gate.nextFinished(t)
	waitForHistory(t, "restarted worker exit", func() bool { return !historyRunning(w) })
	if starts, _, _ := w.stats(); starts != 2 {
		t.Fatalf("worker started %d times, want one lazy start per idle period", starts)
	}
	if gate.calls() != 2 {
		t.Fatalf("worker rendered %d sources, want one per job", gate.calls())
	}
}

// Small settled blocks keep their synchronous first frame: the worker is not
// started and the screen never shows raw Markdown for them.
func TestSmallSettledMarkdownStaysSynchronous(t *testing.T) {
	for _, tc := range []struct {
		name   string
		source string
	}{
		{"short", "**bold** and `code`"},
		{"under_limit", strings.Repeat("wrap me with **bold** text\n", (historyMarkdownSyncLimit-1024)/28)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := interactionModel(t, 80, 24)
			m.appendAssistant(tc.source)
			m.refreshTranscript()
			if len(m.markdownCache) != 1 {
				t.Fatalf("small settled block was not rendered on its mount frame: %d", len(m.markdownCache))
			}
			if m.virtualScroll.history != nil {
				t.Fatal("small settled block started the cold worker")
			}
			if m.historyMarkdownPending() {
				t.Fatal("small settled block reported a pending render")
			}
			plain := ansi.Strip(m.viewport.GetContent())
			if strings.Contains(plain, "**") || !strings.Contains(plain, "bold") {
				t.Fatalf("small settled block painted raw Markdown: %q", plain)
			}
		})
	}
}

// The parent clock needs one predicate that covers a finished but unpainted
// cold render, exactly like the streaming worker's.
func TestPendingColdMarkdownIsReportedForTheClock(t *testing.T) {
	gate := installHistoryRenderGate(t)
	m := interactionModel(t, 80, 24)
	if m.historyMarkdownPending() {
		t.Fatal("a document with no cold render reported work")
	}
	m.appendAssistant(giantHistoryMarkdown(1))
	defer m.closeHistoryMarkdown()
	m.refreshTranscript()
	if !m.historyMarkdownPending() {
		t.Fatal("a giant cold block was not reported as pending")
	}
	gate.allow()
	gate.nextFinished(t)
	settleHistoryMarkdown(t, m)
	if m.historyMarkdownPending() {
		t.Fatal("a painted cold render still reported work")
	}
	m.closeHistoryMarkdown()
	if m.historyMarkdownPending() {
		t.Fatal("a closed cold worker reported work")
	}
}
