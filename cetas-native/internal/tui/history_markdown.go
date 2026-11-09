package tui

import (
	"fmt"
	"sync"
	"time"

	"charm.land/glamour/v2"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// A settled historical block is normally laid out once, on the frame that first
// mounts it: that is bounded work and keeps the screen free of raw Markdown.
// A giant block breaks that bargain — glamour's whole-document layout of a
// multi-hundred-kilobyte message can take long enough that the wheel, the
// reducer and the paint path all wait for it. Above historyMarkdownSyncLimit the
// mount therefore paints the block's truthful plain source and hands the layout
// to the document's single background worker. The completed render replaces the
// fallback rows and height on a later frame, and a result whose block revision,
// width, palette or document epoch no longer matches is discarded.
const (
	// historyMarkdownSyncLimit is the largest cold settled source that may still
	// be rendered synchronously. Below it a render costs less than a dispatch and
	// the first frame is already final; above it the frame must not wait.
	historyMarkdownSyncLimit = 32 << 10
	// historyMarkdownQueueDepth bounds the cold render queue. It is a
	// viewport-sized backlog, not a job per block: scrolling through history can
	// supersede a queued block, and a newer source for the same block replaces
	// its slot instead of growing the queue.
	historyMarkdownQueueDepth = 1
	// historyMarkdownResultLimit bounds completed renders retained for the UI. A
	// frame that has not run yet must not be able to grow the worker's memory.
	historyMarkdownResultLimit = 8
	historyMarkdownResultBytes = 8 << 20
	// defaultHistoryMarkdownIdleExit is how long the worker waits for another
	// cold block before it returns. A document that stops scrolling must not
	// keep a goroutine parked forever; the next submit starts it again.
	defaultHistoryMarkdownIdleExit = 10 * time.Second
)

// historyMarkdownNewRenderer and historyMarkdownRender are the worker's seams.
// Production uses the same renderer factory and render call as the streaming
// worker, so a cold block is painted by exactly the code path a warm one is.
// Tests replace them to hold a render in flight and prove that neither Update
// nor the mount pass waits for it. The seam mutex orders a swap against a worker
// that is already reading the function value, so a test can restore the
// production functions without racing a goroutine it just stopped.
var (
	historyMarkdownSeamMu      sync.RWMutex
	historyMarkdownNewRenderer = newMarkdownRenderer
	historyMarkdownRender      = renderMarkdown
)

func historyMarkdownMakeRenderer(width int, theme ui.Theme) (*glamour.TermRenderer, error) {
	historyMarkdownSeamMu.RLock()
	factory := historyMarkdownNewRenderer
	historyMarkdownSeamMu.RUnlock()
	return factory(width, theme)
}

func historyMarkdownLayout(renderer *glamour.TermRenderer, source string) (string, error) {
	historyMarkdownSeamMu.RLock()
	render := historyMarkdownRender
	historyMarkdownSeamMu.RUnlock()
	return render(renderer, source)
}

// historyMarkdownKey identifies the exact document a result belongs to: the
// document epoch (block indices), the block revision (its source), the terminal
// width and the palette. A late result is validated against all four.
type historyMarkdownKey struct {
	epoch    uint64
	revision uint64
	width    int
	themeKey string
}

// historyMarkdownJob is one cold settled block waiting for a layout. It carries
// its own theme so the worker never reads mutable UI state.
type historyMarkdownJob struct {
	index  int
	key    historyMarkdownKey
	theme  ui.Theme
	source string
}

// historyMarkdownResult carries the job identity back to the UI thread.
type historyMarkdownResult struct {
	index    int
	key      historyMarkdownKey
	rendered string
	err      error
}

// historyMarkdownWorker lays out cold settled blocks away from the Bubble Tea
// update and paint path. Exactly one goroutine serves a document and it starts
// lazily on the first giant block. The queue is bounded, one job per block, and
// completed results are retained under a bound so a slow frame cannot make the
// worker grow without limit. The UI never blocks on it: results are polled on
// the frame it is already drawing.
type historyMarkdownWorker struct {
	mu       sync.Mutex
	capacity int
	// idleExit is how long an empty queue parks the goroutine before it exits.
	// It is fixed before the worker starts, so the goroutine reads it without a
	// lock; a test shortens it to observe the exit.
	idleExit time.Duration
	queue    []historyMarkdownJob
	inflight *historyMarkdownJob
	results  map[int]historyMarkdownResult
	// order is the insertion order of results, used to evict the oldest one when
	// retention is full and to hand results back in completion order.
	order      []int
	wake       chan struct{}
	done       chan struct{}
	running    bool
	generation uint64
	stopped    bool
	// starts counts worker goroutines, runs counts Markdown layouts actually
	// performed and dropped counts jobs a newer source superseded or the bound
	// refused.
	starts, runs, dropped int
}

func newHistoryMarkdownWorker(capacity int) *historyMarkdownWorker {
	return &historyMarkdownWorker{
		capacity: max(1, capacity),
		idleExit: defaultHistoryMarkdownIdleExit,
		results:  map[int]historyMarkdownResult{},
		wake:     make(chan struct{}, 1),
		done:     make(chan struct{}),
	}
}

// submit queues one cold render. A job identical to the one already running or
// queued for that block is ignored, so re-mounting a pending block on every
// frame costs a comparison instead of a render. A newer source for the same
// block replaces its queued slot, and a full queue drops its oldest entry: the
// backlog stays bounded no matter how fast the user scrolls.
func (w *historyMarkdownWorker) submit(job historyMarkdownJob) bool {
	w.mu.Lock()
	if w.stopped {
		w.mu.Unlock()
		return false
	}
	if w.inflight != nil && w.inflight.index == job.index && w.inflight.key == job.key {
		w.mu.Unlock()
		return true
	}
	for i := range w.queue {
		if w.queue[i].index != job.index {
			continue
		}
		if w.queue[i].key == job.key {
			w.mu.Unlock()
			return true
		}
		w.queue[i] = job
		w.dropped++
		w.mu.Unlock()
		return true
	}
	if len(w.queue) >= w.capacity {
		w.queue = append(w.queue[:0], w.queue[1:]...)
		w.dropped++
	}
	w.queue = append(w.queue, job)
	w.ensureRunningLocked()
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
	return true
}

// ensureRunningLocked starts the single worker if it is not already alive. The
// caller holds the mutex, so a stopped worker is never resurrected and two
// submits can never start two goroutines.
func (w *historyMarkdownWorker) ensureRunningLocked() {
	if w.running || w.stopped {
		return
	}
	w.running = true
	w.generation++
	go w.run(w.generation)
}

// run is the single worker. It owns its renderer (rebuilt only when the width
// or palette changes), so no glamour state is shared with the UI thread.
func (w *historyMarkdownWorker) run(generation uint64) {
	w.mu.Lock()
	w.starts++
	w.mu.Unlock()
	defer func() {
		w.mu.Lock()
		// An idle exit may already have handed ownership to a new worker.
		// Its predecessor must not clear the new worker's running flag.
		if w.generation == generation {
			w.running = false
		}
		w.mu.Unlock()
	}()
	var renderer *glamour.TermRenderer
	identity := ""
	for {
		w.mu.Lock()
		if w.stopped {
			w.mu.Unlock()
			return
		}
		job, ok := w.nextLocked()
		w.mu.Unlock()
		if !ok {
			// Nothing to do: park, but not forever. An idle document releases its
			// goroutine instead of keeping it for the life of the process.
			timer := time.NewTimer(w.idleExit)
			select {
			case <-w.wake:
				timer.Stop()
			case <-w.done:
				timer.Stop()
				return
			case <-timer.C:
				// Exit only while the queue is still empty under the lock: a job
				// submitted in this instant starts a fresh worker instead.
				w.mu.Lock()
				empty := len(w.queue) == 0 && !w.stopped
				if empty {
					w.running = false
				}
				w.mu.Unlock()
				if empty {
					return
				}
			}
			continue
		}
		key := fmt.Sprintf("%d/%s", job.key.width, job.key.themeKey)
		if renderer == nil || identity != key {
			next, err := historyMarkdownMakeRenderer(job.key.width, job.theme)
			if err != nil {
				w.finish(historyMarkdownResult{index: job.index, key: job.key, err: err})
				continue
			}
			renderer, identity = next, key
		}
		rendered, err := historyMarkdownLayout(renderer, job.source)
		w.mu.Lock()
		w.runs++
		w.mu.Unlock()
		w.finish(historyMarkdownResult{index: job.index, key: job.key, rendered: rendered, err: err})
	}
}

// nextLocked removes the oldest queued job and marks it in flight. A block that
// was dropped from the queue while in flight is simply not re-rendered.
func (w *historyMarkdownWorker) nextLocked() (historyMarkdownJob, bool) {
	if len(w.queue) == 0 {
		w.inflight = nil
		return historyMarkdownJob{}, false
	}
	job := w.queue[0]
	w.queue[0] = historyMarkdownJob{} // release the dequeued source from the backing array
	w.queue = w.queue[1:]
	if len(w.queue) == 0 {
		w.queue = nil
	}
	w.inflight = &job
	return job, true
}

// finish retains a completed render for the UI, keeping at most one result per
// block and evicting the oldest block when retention is full. A stopped worker
// accepts nothing: shutdown must not resurrect a queue no goroutine will drain.
func (w *historyMarkdownWorker) finish(result historyMarkdownResult) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.inflight = nil
	if w.stopped {
		return
	}
	if len(result.rendered) > historyMarkdownResultBytes {
		result.rendered = ""
		result.err = fmt.Errorf("settled Markdown layout exceeds the 8 MiB retention budget; showing source")
	}
	if _, exists := w.results[result.index]; exists {
		delete(w.results, result.index)
		for i, index := range w.order {
			if index == result.index {
				w.order = append(w.order[:i], w.order[i+1:]...)
				break
			}
		}
	}
	retained := len(result.rendered)
	for _, old := range w.results {
		retained += len(old.rendered)
	}
	for len(w.order) >= historyMarkdownResultLimit || retained > historyMarkdownResultBytes {
		oldest := w.order[0]
		w.order = w.order[1:]
		retained -= len(w.results[oldest].rendered)
		delete(w.results, oldest)
	}
	w.order = append(w.order, result.index)
	w.results[result.index] = result
}

// take hands the oldest completed result to the UI thread, if any. It never
// blocks, so a frame that already exists absorbs the result.
func (w *historyMarkdownWorker) take() (historyMarkdownResult, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.order) == 0 {
		return historyMarkdownResult{}, false
	}
	index := w.order[0]
	w.order = w.order[1:]
	result, ok := w.results[index]
	delete(w.results, index)
	return result, ok
}

// drop forgets everything queued or retained for one block. A render already in
// flight cannot be interrupted, but its revision is stale by the time it lands
// and the pump discards it.
func (w *historyMarkdownWorker) drop(index int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.queue) > 0 {
		kept := w.queue[:0]
		for _, job := range w.queue {
			if job.index == index {
				w.dropped++
				continue
			}
			kept = append(kept, job)
		}
		clear(w.queue[len(kept):])
		w.queue = kept
	}
	if _, ok := w.results[index]; !ok {
		return
	}
	delete(w.results, index)
	for i, at := range w.order {
		if at == index {
			w.order = append(w.order[:i], w.order[i+1:]...)
			break
		}
	}
}

// idle reports whether the worker has nothing queued, nothing running and
// nothing unpainted. A finished but not yet collected result counts as busy so
// the parent's clock keeps a frame coming until it is painted.
func (w *historyMarkdownWorker) idle() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.stopped || len(w.queue) == 0 && w.inflight == nil && len(w.order) == 0
}

// stop ends the worker and forgets every queued or completed render. A session
// switch is a new document: its results must never reach the next one.
func (w *historyMarkdownWorker) stop() {
	w.mu.Lock()
	if w.stopped {
		w.mu.Unlock()
		return
	}
	w.stopped = true
	w.queue = nil
	w.inflight = nil
	w.results = nil
	w.order = nil
	w.mu.Unlock()
	close(w.done)
}

func (w *historyMarkdownWorker) stats() (starts, runs, dropped int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.starts, w.runs, w.dropped
}

// dispatchHistoryMarkdown hands one cold settled block to the document's
// background worker. It reports whether the block will be rendered asynchronously
// at all: without a virtual document there is no document worker to own it.
func (m *model) dispatchHistoryMarkdown(index int, raw string) bool {
	v := m.virtualScroll
	if v == nil || index < 0 || index >= len(m.transcript) {
		return false
	}
	return v.historyMarkdown().submit(historyMarkdownJob{
		index: index,
		key: historyMarkdownKey{
			epoch:    v.epoch,
			revision: v.revisionAt(index),
			width:    max(1, m.viewport.Width()),
			themeKey: m.markdownThemeIdentity(),
		},
		theme:  m.theme(),
		source: raw,
	})
}

// pumpHistoryMarkdown applies completed cold renders whose block, revision,
// width, palette and document epoch are still current. A result of a superseded
// source or display configuration is discarded: the worker's identity is
// validated, never assumed. The applied render invalidates the block's fallback
// rows and height, so the frame that follows measures and paints the real
// layout.
func (m *model) pumpHistoryMarkdown() {
	v := m.virtualScroll
	if v == nil || v.history == nil {
		return
	}
	width := max(1, m.viewport.Width())
	themeKey := m.markdownThemeIdentity()
	for {
		result, ok := v.history.take()
		if !ok {
			return
		}
		index := result.index
		if index < 0 || index >= len(m.transcript) {
			continue
		}
		if result.key.epoch != v.epoch || result.key.width != width || result.key.themeKey != themeKey {
			continue
		}
		if v.revisionAt(index) != result.key.revision {
			continue
		}
		if result.err != nil {
			m.err = "Markdown render failed: " + result.err.Error()
			// Keep the complete plain source for this unchanged display identity,
			// rather than retrying a failing render every 50 ms forever.
			result.rendered = m.rawTranscriptBlock(index)
		}
		if m.markdownCache == nil {
			m.markdownCache = make(map[int]string)
		}
		m.markdownCache[index] = result.rendered
		// The mounted rows and height were laid out from the plain fallback:
		// both describe the old source and must be derived again.
		v.bumpRevision(index)
		if index < len(v.heights) {
			v.setHeight(index, estimateTranscriptHeight(m.rawTranscriptBlock(index), width))
		}
	}
}

// historyMarkdownPending reports whether a cold settled Markdown render is still
// queued, running or unpainted. It is the history counterpart of
// markdownRenderPending: nextUIWake should treat
// `markdownRenderPending() || historyMarkdownPending()` like an animation, or a
// giant historical block keeps showing its plain source until the next input
// event arrives.
func (m *model) historyMarkdownPending() bool {
	return m.virtualScroll != nil && m.virtualScroll.history != nil && !m.virtualScroll.history.idle()
}

// closeHistoryMarkdown releases the document's cold render worker. It belongs
// next to document.markdown.stop() in model.Close so a quit path that bypasses
// Update leaves no goroutine behind.
func (m *model) closeHistoryMarkdown() {
	if m.virtualScroll != nil && m.virtualScroll.history != nil {
		m.virtualScroll.history.stop()
	}
}
