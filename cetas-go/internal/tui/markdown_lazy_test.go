package tui

import (
	"strings"
	"testing"

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
