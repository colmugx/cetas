package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
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

// Literal highlighting must survive ANSI styling without changing the visible
// width, and must refuse Markdown sources it cannot map onto painted rows.
func TestSearchHighlightUnderlinesLiteralRows(t *testing.T) {
	rows := []string{"\x1b[33mbanana asked main\x1b[0m"}
	out := highlightLiteralRows(rows, "banana asked main", []transcriptSearchHit{{offset: 0, length: 6}}, 80)
	if len(out) != 1 || !strings.Contains(out[0], "\x1b[4m") || !strings.Contains(out[0], "banana") {
		t.Fatalf("literal match not underlined: %q", out)
	}
	if ansi.StringWidth(out[0]) != ansi.StringWidth(rows[0]) {
		t.Fatalf("highlight changed the row width: %q", out[0])
	}
	if got := highlightLiteralRows([]string{"shown"}, "**banana**", []transcriptSearchHit{{offset: 2, length: 6}}, 80); got[0] != "shown" {
		t.Fatalf("uncertain Markdown source was highlighted: %q", got)
	}
	image := "\x1b_Ga=T;payload\x1b\\"
	if got := highlightLiteralRows([]string{image}, "banana", []transcriptSearchHit{{offset: 0, length: 6}}, 80); got[0] != image {
		t.Fatal("image payload was rewritten by the highlighter")
	}
	if got := highlightLiteralRows([]string{"banana"}, "", nil, 80); got[0] != "banana" {
		t.Fatal("empty search state rewrote a row")
	}
}

// Per-block lookup keeps a repaint O(log matches); the flat hit list stays the
// single snapshot the navigation index uses.
func TestSearchHitsAtBlockLookup(t *testing.T) {
	hits := transcriptMatches([]string{"one hit", "nothing", "hit hit", "hit"}, nil, "hit")
	if len(hits) != 4 {
		t.Fatalf("unexpected snapshot: %#v", hits)
	}
	if got := hitsAt(hits, 0); len(got) != 1 || got[0].offset != 4 {
		t.Fatalf("block 0 hits: %#v", got)
	}
	if got := hitsAt(hits, 1); len(got) != 0 {
		t.Fatalf("block 1 hits: %#v", got)
	}
	if got := hitsAt(hits, 2); len(got) != 2 || got[0].offset != 0 || got[1].offset != 4 {
		t.Fatalf("block 2 hits: %#v", got)
	}
	if got := hitsAt(hits, 3); len(got) != 1 || got[0].offset != 0 {
		t.Fatalf("block 3 hits: %#v", got)
	}
	if got := hitsAt(hits, 99); len(got) != 0 {
		t.Fatalf("missing block hits: %#v", got)
	}
}

// The mounted window paints only its own literal hits: a hit-cap that excludes
// an offscreen match must not leak into a visible frame, and a re-search that
// isolates the visible block must underline exactly that literal text.
func TestSearchHighlightOnlyAffectsMountedBlocks(t *testing.T) {
	m := newModel()
	m.width, m.height = 50, 20
	m.resize()
	for i := 0; i < 6000; i++ {
		line := "plain"
		if i < 5000 {
			line = "banana banana"
		}
		if i == 5900 {
			line = "banana target"
		}
		m.transcript = append(m.transcript, line)
	}
	m.refreshTranscript()
	m.jumpToTranscriptBlock(5900)
	m.findTranscript("banana")
	if len(m.searchHits) != maxTranscriptSearchHits {
		t.Fatalf("search cap regressed: %d hits", len(m.searchHits))
	}
	// find navigates to the first hit; return to the visible target block to
	// prove the capped-away hits are not painted there.
	m.jumpToTranscriptBlock(5900)
	if strings.Contains(m.viewport.GetContent(), "\x1b[4m") {
		t.Fatal("capped-away offscreen hits were painted")
	}
	m.findTranscript("target")
	if len(m.searchHits) != 1 || m.searchHits[0].block != 5900 {
		t.Fatalf("single-hit search: %#v", m.searchHits)
	}
	content := m.viewport.GetContent()
	if !strings.Contains(content, "\x1b[4mtarget\x1b[24m") {
		t.Fatalf("visible literal hit was not underlined: %q", ansi.Strip(content))
	}
	if strings.Count(content, "\x1b[4m") != 1 {
		t.Fatalf("highlighted unrelated rows: %d", strings.Count(content, "\x1b[4m"))
	}
	m.clearTranscriptSearch()
	m.refreshTranscript()
	if strings.Contains(m.viewport.GetContent(), "\x1b[4m") {
		t.Fatal("clearing the search left underlined rows")
	}
}
