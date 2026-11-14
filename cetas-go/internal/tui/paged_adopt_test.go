package tui

import (
	"strings"
	"testing"

	transcriptui "github.com/colmugx/cetas/cetas-go/internal/tui/transcript"
)

// The live tail the conversation appends since the last index is the last
// unbounded retention surface in the document: this test pins its conversion
// into budget-managed paged blocks. A settled turn with a heavy tail re-indexes;
// the projected run is adopted in place (moved to its absolute index, registered
// as a synthesized resident page) without duplicating anything, the UI-local
// notices that shared the tail ride behind it in order, and eviction releases
// the adopted sources exactly like a page read from the journal.
func TestLiveTailAdoptionBoundsTheMirror(t *testing.T) {
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: "journal question"},
		{Index: 1, Kind: "assistant", Text: "journal answer"},
	}
	host := &pagedTestHost{session: "s-1", revision: "2048:1:1", corpus: corpus, indexWindow: 400}
	m, r := pagedHostModel(t, host)
	pagedLoadAll(t, &m, r, host)
	if r.total != 2 || len(m.transcript) != 2 {
		t.Fatalf("baseline document = %d blocks (total %d)", len(m.transcript), r.total)
	}

	// A turn runs live: a notice, the projected run (user, thinking, answer),
	// and the turn-completed notice trailing it. The answer alone crosses the
	// adoption threshold.
	appendTestNotice := func(text string) {
		at := len(m.transcript)
		m.transcript = append(m.transcript, "● "+text)
		m.blocks[at] = transcriptui.Block{Kind: "notice", Text: text}
	}
	appendTestNotice("mid-turn notice")
	m.appendUser("live question")
	m.appendThinking("live reasoning")
	m.appendAssistant(strings.Repeat("live answer ", 96000))
	appendTestNotice("Cetas: turn completed")
	if len(m.transcript) != 7 {
		t.Fatalf("live tail document = %d blocks, want 7", len(m.transcript))
	}
	if cmd := r.refreshForTailGrowth(&m); cmd == nil {
		t.Fatal("a heavy live tail did not request a re-index")
	}

	// The journal settled: the corpus gains exactly the projected run and a
	// new revision. The index reply adopts the tail.
	host.corpus = append(host.corpus,
		pagedItem{Index: 2, Kind: "user", Text: "live question"},
		pagedItem{Index: 3, Kind: "thinking", Text: "live reasoning"},
		pagedItem{Index: 4, Kind: "assistant", Text: strings.Repeat("live answer ", 96000)},
	)
	host.revision = "1120000:2:2"
	pagedDrive(t, &m, r, r.refresh(&m))

	if r.total != 5 {
		t.Fatalf("adoption did not advance the journal boundary: total = %d", r.total)
	}
	if len(m.transcript) != 7 {
		t.Fatalf("adoption duplicated blocks: document = %d, want 7", len(m.transcript))
	}
	// The projected run sits at its absolute indexes; both notices survive
	// behind it, in order.
	if got := m.transcript[2]; got != "> live question" {
		t.Fatalf("adopted user block at 2 = %q", got)
	}
	if !strings.HasPrefix(m.transcript[3], "💭 thought · 1 lines") {
		t.Fatalf("adopted thinking block at 3 = %q", m.transcript[3])
	}
	if !strings.HasPrefix(m.transcript[4], "live answer ") {
		t.Fatalf("adopted answer block at 4 = %q", m.transcript[4])
	}
	if !strings.Contains(m.transcript[5], "mid-turn notice") || !strings.Contains(m.transcript[6], "turn completed") {
		t.Fatalf("notices lost or reordered: %q / %q", m.transcript[5], m.transcript[6])
	}
	// The run is registered as one synthesized resident page under the budget.
	page, held := r.pages[2]
	if !held || len(page.indices) != 3 {
		t.Fatalf("adopted run is not one resident page: held=%v indices=%v", held, page.indices)
	}
	for _, block := range []int{2, 3, 4} {
		if _, held := r.resident[block]; !held {
			t.Fatalf("adopted block %d is not resident", block)
		}
	}
	if r.bytes <= 0 {
		t.Fatal("adopted run is not accounted in the resident budget")
	}

	// Eviction releases the adopted sources; reading the span back re-requests
	// the page from the journal and restores identical content.
	before := m.transcript[4]
	r.dropPage(&m, page)
	if m.transcript[2] != "" || m.transcript[4] != "" {
		t.Fatalf("eviction kept adopted sources: %q / %q", m.transcript[2], m.transcript[4])
	}
	host.requests = nil
	// Scrolling back over the released span re-requests it from the journal.
	r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(2, pagedPageLimit)})
	if m.transcript[2] != "> live question" || m.transcript[4] != before {
		t.Fatalf("re-paged run differs: %q / %q", m.transcript[2], m.transcript[4])
	}
}

// A live tail whose projected shape cannot match the journal (a failed turn
// appends an error row the journal never persisted) must keep its raw blocks
// verbatim instead of adopting a wrong mapping or duplicating placeholders.
func TestLiveTailAdoptionRefusesMismatchedShapes(t *testing.T) {
	corpus := []pagedItem{{Index: 0, Kind: "user", Text: "journal question"}}
	host := &pagedTestHost{session: "s-1", revision: "2048:1:1", corpus: corpus, indexWindow: 400}
	m, r := pagedHostModel(t, host)
	pagedLoadAll(t, &m, r, host)

	m.appendUser("doomed question")
	// The journal persisted the prompt but not the error row: the error row is
	// a UI-local diagnostic (its block entry says so), so the shapes still map
	// and adoption converts the prompt, leaving the error row in the tail.
	at := len(m.transcript)
	m.transcript = append(m.transcript, "Error: provider refused")
	m.blocks[at] = transcriptui.Block{Kind: "error", Text: "provider refused"}
	host.corpus = append(host.corpus, pagedItem{Index: 1, Kind: "user", Text: "doomed question"})
	host.revision = "4096:2:2"
	pagedDrive(t, &m, r, r.refresh(&m))

	if r.total != 2 {
		t.Fatalf("the adoptable tail did not advance the boundary: total = %d", r.total)
	}
	if len(m.transcript) != 3 {
		t.Fatalf("tail was duplicated or dropped: %d blocks", len(m.transcript))
	}
	if m.transcript[1] != "> doomed question" || m.transcript[2] != "Error: provider refused" {
		t.Fatalf("tail mutated: %q / %q", m.transcript[1], m.transcript[2])
	}
	// A genuinely mismatched shape (a raw row with no block and no journal
	// counterpart) keeps its raw blocks instead of adopting a wrong mapping.
	m.transcript = append(m.transcript, "orphan row nobody projected")
	host.revision = "5120:3:3"
	pagedDrive(t, &m, r, r.refresh(&m))
	if r.total != 2 {
		t.Fatalf("mismatched tail advanced the boundary to %d", r.total)
	}
	if len(m.transcript) != 4 || m.transcript[3] != "orphan row nobody projected" {
		t.Fatalf("raw orphan row disturbed: %d blocks, tail %q", len(m.transcript), m.transcript[3])
	}
}

// Below the threshold the tail is both the freshest and the cheapest copy of
// what the user is reading; no re-index is issued for it.
func TestLiveTailAdoptionThreshold(t *testing.T) {
	host := &pagedTestHost{session: "s-1", revision: "2048:1:1", corpus: pagedUserCorpus(2), indexWindow: 400}
	m, r := pagedHostModel(t, host)
	m.appendUser("light question")
	m.appendAssistant("light answer")
	if cmd := r.refreshForTailGrowth(&m); cmd != nil {
		t.Fatal("a light live tail triggered a re-index")
	}
}

// A fresh session has no id at ready time, so the initial replay probe never
// fired and the document runs live and unindexed. The turn-end hook must index
// it for the first time, and that first index adopts the live document instead
// of rebuilding it, so the conversation on screen never flashes away.
func TestLiveTailAdoptionIndexesAFreshSession(t *testing.T) {
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: "first question"},
		{Index: 1, Kind: "assistant", Text: strings.Repeat("first answer ", 96000)},
	}
	host := &pagedTestHost{session: "s-1", revision: "2048:1:1", corpus: nil, indexWindow: 400}
	m := newModel()
	m.width, m.height = 80, 48
	m.resize()
	m.host = host
	r := newPagedReplay()
	if cmd := r.start(&m); cmd != nil {
		t.Fatal("a sessionless start issued a request")
	}
	if r.indexed {
		t.Fatal("sessionless start reported an index")
	}
	// The first turn names the session and runs entirely live.
	m.session = "s-1"
	m.appendUser("first question")
	m.appendAssistant(strings.Repeat("first answer ", 96000))
	if cmd := r.refreshForTailGrowth(&m); cmd == nil {
		t.Fatal("a heavy unindexed live tail did not request the first index")
	}
	host.corpus = corpus
	pagedDrive(t, &m, r, r.refreshForTailGrowth(&m))
	if !r.indexed || r.total != 2 {
		t.Fatalf("first index did not adopt the live document: indexed=%v total=%d", r.indexed, r.total)
	}
	if len(m.transcript) != 2 || m.transcript[0] != "> first question" {
		t.Fatalf("first index rebuilt instead of adopting: %q", m.transcript)
	}
	if _, held := r.pages[0]; !held {
		t.Fatal("adopted document is not registered as a resident page")
	}
	if m.replayLiveFrom != 2 || m.replayLiveSession != "s-1" {
		t.Fatalf("journal boundary watermark not marked: %d/%q", m.replayLiveFrom, m.replayLiveSession)
	}
	// A replay restart over the same session must not re-adopt history: the
	// watermark pins the boundary, so the second index rebuilds (retiring
	// runtime notices) exactly like a session switch would.
	pagedDrive(t, &m, r, r.start(&m))
	if r.total != 2 || len(m.transcript) != 2 {
		t.Fatalf("restarted replay disturbed the document: total=%d blocks=%d", r.total, len(m.transcript))
	}
	if m.replayLiveFrom != 2 || m.replayLiveSession != "s-1" {
		t.Fatalf("restart lost the watermark: %d/%q", m.replayLiveFrom, m.replayLiveSession)
	}
}
