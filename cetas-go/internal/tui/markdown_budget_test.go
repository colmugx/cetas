package tui

import (
	"strings"
	"testing"
	"time"
)

func TestWholeMarkdownBudgetIsCheckedBeforeRendererEntry(t *testing.T) {
	// nil would panic if the source reached Glamour. Rejecting after Render
	// returns cannot protect against its whole-document allocation peak.
	raw := strings.Repeat("x", maxWholeMarkdownSourceBytes+1)
	text, err := renderMarkdown(nil, raw)
	if err == nil || text != "" || !strings.Contains(err.Error(), "complete plain source") {
		t.Fatalf("oversized layout was not explicitly refused before render: %v", err)
	}
}

func TestOversizedLiveMarkdownKeepsEveryDeltaAsPlainSource(t *testing.T) {
	m := newModel()
	defer m.Close()
	raw := strings.Repeat("x", maxWholeMarkdownSourceBytes+1)
	if got := m.renderLiveMarkdown(0, raw); got != raw {
		t.Fatal("oversized initial message was truncated")
	}
	raw += "\nLATEST DELTA"
	if got := m.renderLiveMarkdown(0, raw); got != raw {
		t.Fatal("oversized live message kept an obsolete rendered prefix")
	}
	if m.markdownRenderPending() {
		t.Fatal("oversized live deltas still scheduled whole-document layouts")
	}
	if !strings.Contains(m.err, "complete plain source") {
		t.Fatal("plain-source degradation was silent")
	}
}

func TestOversizedHistoryLayoutFallsBackOnceWithoutLosingSource(t *testing.T) {
	m := newModel()
	defer m.Close()
	raw := strings.Repeat("paragraph\n", maxWholeMarkdownSourceBytes/10+1)
	m.appendAssistant(raw)
	m.refreshTranscript()
	deadline := time.Now().Add(time.Second)
	for m.historyMarkdownPending() {
		if time.Now().After(deadline) {
			t.Fatal("rejected layout did not settle")
		}
		time.Sleep(time.Millisecond)
		m.refreshTranscript()
	}
	if m.transcriptBlockText(0) != raw || m.transcriptSourceAt(0) != raw {
		t.Fatal("fallback lost full history source")
	}
	if !strings.Contains(m.err, "complete plain source") {
		t.Fatal("fallback has no visible reason")
	}
	if m.historyMarkdownPending() {
		t.Fatal("unchanged oversized history immediately retried a layout")
	}
}
