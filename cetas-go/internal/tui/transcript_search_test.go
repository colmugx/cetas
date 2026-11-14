package tui

import (
	"fmt"
	"strings"
	"testing"
)

func TestTranscriptSearchFullSourceAndWrap(t *testing.T) {
	var lines []string
	for i := 0; i < 3000; i++ {
		lines = append(lines, fmt.Sprintf("line %d", i))
	}
	lines[8] = "needle initial"
	lines[2998] = "needle needle final"
	hidden := []hiddenTranscriptSource{{block: 17, text: "HIDDEN needle tool output"}}
	hits := transcriptMatches(lines, hidden, "NEEDLE")
	if len(hits) != 4 {
		t.Fatalf("full transcript search should include offscreen and hidden matches: %#v", hits)
	}
	if hits[0].block != 8 || hits[1].block != 17 || !hits[1].hidden || hits[2].block != 2998 || hits[3].block != 2998 {
		t.Fatalf("search hits out of document order: %#v", hits)
	}
	m := newModel()
	m.width, m.height = 80, 25
	m.resize()
	m.transcript = lines
	m.hiddenSearchSources = hidden
	m.refreshTranscript()
	m.findTranscript("NEEDLE")
	if m.searchActive != 0 || len(m.searchHits) != 4 {
		t.Fatalf("first search hit missing: %#v", m.searchHits)
	}
	m.navigateTranscriptSearch(true)
	if m.searchActive != 3 || m.virtualScroll == nil || m.virtualScroll.top <= 0 {
		t.Fatalf("reverse must wrap to final offscreen match: active=%d offset=%d", m.searchActive, m.virtualScroll.top)
	}
	m.navigateTranscriptSearch(false)
	if m.searchActive != 0 {
		t.Fatalf("next must wrap back to first match: %d", m.searchActive)
	}
}

func TestFindCommandsNeverDispatchHarnessAndPreserveDraft(t *testing.T) {
	m := newModel()
	m.transcript = []string{"first match", "second match"}
	m.refreshTranscript()
	cmd := m.command("/find match")
	if cmd != nil || m.searchActive != 0 {
		t.Fatalf("find must stay local: cmd=%v index=%d", cmd, m.searchActive)
	}
	cmd = m.command("/find-next")
	if cmd != nil || m.searchActive != 1 {
		t.Fatal("find-next must stay local and navigate")
	}
	cmd = m.command("/find-prev")
	if cmd != nil || m.searchActive != 0 {
		t.Fatal("find-prev must stay local and navigate")
	}
	m.command("/find absent")
	if len(m.searchHits) != 0 || !strings.Contains(m.status, "no transcript matches") {
		t.Fatalf("empty result must be explicit: %#v %q", m.searchHits, m.status)
	}
	if len(slashSuggestions("/find")) < 3 {
		t.Fatal("all three native search commands should be discoverable")
	}
}
