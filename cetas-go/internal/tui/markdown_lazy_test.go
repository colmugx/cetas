package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// A cold model must stay cold: nothing in construction, resize or a plain
// refresh may build the styling pipeline. This is the DLL/idle-load contract
// — an unused process carries no styling tables or code pages.
func TestColdModelDoesNotBuildMarkdownRenderer(t *testing.T) {
	m := newModel()
	m.width, m.height = 100, 30
	m.resize()
	m.refreshTranscript()
	if m.markdownRenderer != nil {
		t.Fatal("construction or layout warmed the Markdown renderer")
	}
	if m.document.markdown != nil {
		t.Fatal("construction started a Markdown worker")
	}
}

// First presence (a key or pointer event) warms the pipeline exactly once,
// and a later resize keeps it warm with the new width.
func TestFirstPresenceWarmsMarkdownRenderer(t *testing.T) {
	m := newModel()
	m.width, m.height = 100, 30
	m.resize()
	if m.markdownRenderer != nil {
		t.Fatal("precondition: renderer already warm")
	}
	next, _ := m.Update(tea.KeyPressMsg{Text: "x"})
	m = next.(model)
	if m.markdownRenderer == nil {
		t.Fatal("a key event did not warm the Markdown renderer")
	}
	first := m.markdownRenderer
	next, _ = m.Update(tea.KeyPressMsg{Text: "y"})
	m = next.(model)
	if m.markdownRenderer != first {
		t.Fatal("presence re-created an already-warm renderer")
	}
}

// While cold, a block renders as its truthful plain source and no background
// worker is scheduled — degraded, never broken.
func TestColdBlockRendersPlainWithoutWorker(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	raw := "# Heading\n\nbody"
	m.transcript = append(m.transcript, raw)
	if got := m.mountedTranscriptBlock(0); got != padTranscriptBlock(raw, m.viewport.Width()) {
		t.Fatalf("cold block is not its plain source:\n got %q", ansi.Strip(got))
	}
	if m.document.markdown != nil {
		t.Fatal("cold render started a Markdown worker")
	}
	if strings.Contains(m.err, "Markdown") {
		t.Fatalf("cold degradation reported a styling error: %q", m.err)
	}
}
