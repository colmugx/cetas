package main

import (
	"encoding/json"
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

func TestSearchIndexesCollapsedTranscriptSources(t *testing.T) {
	m := newModel()
	m.session = "test"
	reply := commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[{"kind":"user","text":"hello"},{"kind":"reasoning","text":"private reasoning needle"},{"kind":"assistant","text":"reply"},{"kind":"tool","name":"bash","result":"hidden tool needle output"}]}`)}
	next, _ := m.Update(reply)
	state := next.(model)
	if len(state.transcript) != 3 || len(state.hiddenSearchSources) != 2 {
		t.Fatalf("collapsed content not indexed: visible=%#v hidden=%#v", state.transcript, state.hiddenSearchSources)
	}
	state.findTranscript("needle")
	if len(state.searchHits) != 2 || !state.searchHits[0].hidden || !state.searchHits[1].hidden {
		t.Fatalf("search should find both collapsed sources: %#v", state.searchHits)
	}
	if !strings.Contains(state.status, "collapsed source") {
		t.Fatalf("hidden hit must be reported without revealing source: %q", state.status)
	}
	state.clearTranscriptSearch()
	if state.searchQuery != "" || len(state.searchHits) != 0 || len(state.hiddenSearchSources) != 0 {
		t.Fatal("session change must remove old search sources")
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

func TestTranscriptSearchHitCap(t *testing.T) {
	hits := transcriptMatches([]string{strings.Repeat("a", maxTranscriptSearchHits+100)}, nil, "a")
	if len(hits) != maxTranscriptSearchHits {
		t.Fatalf("bounded search got %d matches", len(hits))
	}
}
