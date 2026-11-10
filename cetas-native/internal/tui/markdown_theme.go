package tui

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"charm.land/glamour/v2"
	ga "charm.land/glamour/v2/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// Use the same semantic palette as the shell, not Glamour's independent dark
// preset. In particular an OSC reply arriving after startup must update both.
func newMarkdownRenderer(width int, theme ui.Theme) (*glamour.TermRenderer, error) {
	color := func(role string) *string {
		c := theme.Color(role)
		if c == nil {
			return nil
		}
		r, g, b, _ := c.RGBA()
		value := fmt.Sprintf("#%02x%02x%02x", r>>8, g>>8, b>>8)
		return &value
	}
	yes := true
	margin, indent := uint(0), uint(1)
	accent, muted, warning := color("accent"), color("muted"), color("warning")
	heading := ga.StyleBlock{StylePrimitive: ga.StylePrimitive{Bold: &yes, Color: accent, BlockSuffix: "\n"}}
	style := ga.StyleConfig{
		Document:  ga.StyleBlock{Margin: &margin, Indent: &indent},
		Paragraph: ga.StyleBlock{StylePrimitive: ga.StylePrimitive{BlockSuffix: "\n"}},
		Heading:   heading, H1: heading, H2: heading, H3: heading, H4: heading, H5: heading, H6: heading,
		Strong: ga.StylePrimitive{Bold: &yes}, Emph: ga.StylePrimitive{Italic: &yes},
		Strikethrough:  ga.StylePrimitive{CrossedOut: &yes},
		Code:           ga.StyleBlock{StylePrimitive: ga.StylePrimitive{Color: warning}},
		CodeBlock:      ga.StyleCodeBlock{StyleBlock: ga.StyleBlock{StylePrimitive: ga.StylePrimitive{Color: muted, BlockSuffix: "\n"}}},
		BlockQuote:     ga.StyleBlock{StylePrimitive: ga.StylePrimitive{Color: muted}, IndentToken: ptr("│ "), Indent: &indent},
		Item:           ga.StylePrimitive{BlockPrefix: "• ", Color: accent},
		Enumeration:    ga.StylePrimitive{BlockPrefix: ". "},
		Link:           ga.StylePrimitive{Color: accent, Underline: &yes},
		LinkText:       ga.StylePrimitive{Color: accent},
		HorizontalRule: ga.StylePrimitive{Format: "────────────────", Color: muted},
	}
	return glamour.NewTermRenderer(glamour.WithWordWrap(max(1, width-2)), glamour.WithStyles(style))
}
func ptr[T any](v T) *T { return &v }

// markdownThemeIdentity is the (foreground, background) key a render belongs to.
// layout.reflow stores the same string in markdownThemeKey; computing it on
// demand lets a background render validate the palette it was queued with.
func (m *model) markdownThemeIdentity() string {
	return fmt.Sprintf("%v/%v", m.surface.fg, m.surface.bg)
}

// Until semantic range rendering replaces whole-document Glamour layouts, do
// not let a single giant message construct an unbounded AST/styled output. This
// is a safety fallback, not complete large-Markdown parity: callers retain and
// display the full plain source and report the reason. The result-cache budget
// alone is too late to prevent the renderer's allocation peak.
const maxWholeMarkdownSourceBytes = 1 << 20

func wholeMarkdownBudgetError() error {
	return fmt.Errorf("Markdown layout exceeds the %d-byte whole-document budget; displaying complete plain source (not truncated)", maxWholeMarkdownSourceBytes)
}

// renderMarkdown runs one document through a renderer. Glamour terminates every
// document with a newline; the transcript owns the inter-block spacing, so the
// trailing blank line is dropped here exactly once for live and settled blocks.
func renderMarkdown(renderer *glamour.TermRenderer, source string) (string, error) {
	if len(source) > maxWholeMarkdownSourceBytes {
		return "", wholeMarkdownBudgetError()
	}
	result, err := renderer.Render(source)
	if err != nil {
		return "", err
	}
	return strings.TrimRight(result, "\n"), nil
}

// markdownCoalesceDelay is the minimum gap between two whole-document renders
// on the worker. Token deltas arrive far faster than one Markdown layout; a
// burst is coalesced into a single pending job instead of a render (or worse a
// goroutine) per token, which is the native equivalent of the JS
// markdown-stream paragraph checkpoint cadence.
const markdownCoalesceDelay = 50 * time.Millisecond

// markdownRenderJob is one immutable render request. revision, width and
// themeKey identify the exact source and display configuration, so a late
// result can be validated against the current one instead of trusted.
type markdownRenderJob struct {
	revision uint64
	width    int
	themeKey string
	theme    ui.Theme
	source   string
}

// markdownRenderResult carries the job identity back to the UI thread.
type markdownRenderResult struct {
	revision uint64
	width    int
	themeKey string
	rendered string
	err      error
}

// markdownPipeline keeps expensive Markdown layout off the Bubble Tea update
// and paint path. Exactly one worker goroutine serves a document, and the queue
// holds a single slot: a newer source replaces a pending one. The UI never
// blocks on it — completed results are polled on the frame it is already
// drawing, so a slow render costs latency, never responsiveness.
type markdownPipeline struct {
	mu      sync.Mutex
	pending *markdownRenderJob
	result  *markdownRenderResult
	wake    chan struct{}
	done    chan struct{}
	applied uint64
	stopped bool
	working bool
	// starts counts worker goroutines (always one), runs counts Markdown
	// renders actually performed and dropped counts sources that a newer delta
	// coalesced away before they were rendered.
	starts, runs, dropped int
}

func newMarkdownPipeline() *markdownPipeline {
	p := &markdownPipeline{
		wake: make(chan struct{}, 1),
		done: make(chan struct{}),
	}
	go p.run()
	return p
}

// run is the single worker. It owns its own renderer (per width and theme), so
// no glamour state is shared with the UI thread.
func (p *markdownPipeline) run() {
	p.mu.Lock()
	p.starts++
	p.mu.Unlock()
	var renderer *glamour.TermRenderer
	identity := ""
	// One reusable coalesce timer: a per-render time.After allocated a fresh
	// timer that only the collector could retire.
	coalesce := time.NewTimer(markdownCoalesceDelay)
	defer coalesce.Stop()
	for {
		p.mu.Lock()
		job := p.pending
		p.pending = nil
		if job != nil {
			p.working = true
		}
		stopped := p.stopped
		p.mu.Unlock()
		if job == nil {
			if stopped {
				return
			}
			select {
			case <-p.wake:
			case <-p.done:
				return
			}
			continue
		}
		key := fmt.Sprintf("%d/%s", job.width, job.themeKey)
		if renderer == nil || identity != key {
			next, err := newMarkdownRenderer(job.width, job.theme)
			if err != nil {
				p.finish(markdownRenderResult{revision: job.revision, width: job.width, themeKey: job.themeKey, err: err})
				continue
			}
			renderer, identity = next, key
		}
		rendered, err := renderMarkdown(renderer, job.source)
		p.mu.Lock()
		p.runs++
		p.mu.Unlock()
		p.finish(markdownRenderResult{revision: job.revision, width: job.width, themeKey: job.themeKey, rendered: rendered, err: err})
		// Give the next delta a chance to merge into one document render.
		// A tick left over from an idle period closes this one window early —
		// harmless, since no deltas were racing while the worker was idle.
		select {
		case <-coalesce.C:
		case <-p.done:
			return
		}
		coalesce.Reset(markdownCoalesceDelay)
	}
}

func (p *markdownPipeline) finish(result markdownRenderResult) {
	p.mu.Lock()
	p.working = false
	// Revisions only grow within one document, so a late completion of a
	// superseded source can never replace a newer one.
	if !p.stopped && result.revision > p.applied {
		p.applied = result.revision
		p.result = &result
	}
	p.mu.Unlock()
}

// idle reports whether the worker has nothing queued and nothing running. A
// finished but not yet collected result counts as busy.
func (p *markdownPipeline) idle() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.stopped || p.pending == nil && p.result == nil && !p.working
}

// submit queues at most one render. The pending slot is replaced, which is how a
// token burst coalesces. A stopped pipeline accepts nothing: shutdown must not
// resurrect a queue that no worker will ever drain.
func (p *markdownPipeline) submit(job markdownRenderJob) {
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return
	}
	if p.pending != nil {
		p.dropped++
	}
	p.pending = &job
	p.mu.Unlock()
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// take hands the newest completed result to the UI thread, if any.
func (p *markdownPipeline) take() (markdownRenderResult, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.result == nil {
		return markdownRenderResult{}, false
	}
	result := *p.result
	p.result = nil
	return result, true
}

func (p *markdownPipeline) stats() (starts, runs, dropped int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.starts, p.runs, p.dropped
}

// stop ends the worker and forgets any pending work. A session switch is a new
// document: its results must never reach the next one.
func (p *markdownPipeline) stop() {
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return
	}
	p.stopped = true
	p.pending = nil
	p.result = nil
	p.mu.Unlock()
	close(p.done)
}
