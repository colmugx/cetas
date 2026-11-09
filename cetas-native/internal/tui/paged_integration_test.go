package tui

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestRetiredReplayRequestFailureCannotStopCurrentSession(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "current"
	m.replay = newPagedReplay()
	m.replay.session = "current"
	for i := 0; i < 5; i++ {
		next, _ := m.Update(commandResult{name: "transcript_page", requestSession: "retired", err: errors.New("old request timed out")})
		m = next.(model)
	}
	if m.replay.failed() || m.err != "" || m.presentedError != "" {
		t.Fatalf("a retired request poisoned the current document: %s / %s", m.status, m.presentedError)
	}
}

func TestInitialAttachDoesNotDuplicateColdIndexRequests(t *testing.T) {
	m := newModel()
	defer m.Close()
	h := &pagedTestHost{session: "saved", revision: "100:1:0", corpus: pagedUserCorpus(50)}
	m.host = h
	_, cmd := m.Update(commandResult{name: "runtime_state", payload: json.RawMessage(`{"session_id":"saved","status":"ready"}`)})
	_ = pagedResults(cmd)
	count := 0
	for _, req := range h.requests {
		if req.command == "transcript_index" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("one attach sent %d cold index requests", count)
	}
}

func TestReplayReadFailureIsATranscriptNotice(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "saved"
	m.replay = newPagedReplay()
	m.replay.session = "saved"
	next, _ := m.Update(commandResult{name: "transcript_index", requestSession: "saved", err: errors.New("fixture unreadable")})
	m = next.(model)
	if !strings.Contains(m.presentedError, "fixture unreadable") {
		t.Fatalf("replay read error did not reach transcript notice: %q", m.presentedError)
	}
}

func TestSameSessionRestartRejectsOldIndexAndReadErrors(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "saved"
	h := &pagedTestHost{session: "saved", revision: "old", corpus: pagedUserCorpus(20)}
	m.host = h
	old := pagedResults(m.startPagedReplay())
	if len(old) != 1 {
		t.Fatalf("expected one old index request, got %d", len(old))
	}
	h.revision = "new"
	fresh := m.startPagedReplay()
	m.applyPagedReply(old[0])
	if m.replay.indexed || m.replay.revision != "" || len(m.transcript) != 0 {
		t.Fatalf("retired same-session index initialized the new document: %q", m.replay.revision)
	}
	old[0].payload = nil
	old[0].err = errors.New("retired index timed out")
	m.applyPagedReply(old[0])
	if m.err != "" || m.replay.failed() {
		t.Fatalf("old same-session error reached the new document: %q", m.err)
	}
	for _, result := range pagedResults(fresh) {
		m.applyPagedReply(result)
	}
	if m.replay.revision != "new" {
		t.Fatalf("fresh index lost: %q", m.replay.revision)
	}
}

func TestColdIndexFailureCanRetryWithoutDuplicateInflightReads(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "saved"
	m.host = &pagedTestHost{session: "saved", revision: "new", corpus: pagedUserCorpus(20)}
	results := pagedResults(m.startPagedReplay())
	if m.ensureTranscriptPages() != nil {
		t.Fatal("an in-flight cold index was duplicated")
	}
	results[0].payload = nil
	results[0].err = errors.New("transient fixture timeout")
	m.applyPagedReply(results[0])
	if cmd := m.ensureTranscriptPages(); cmd == nil {
		t.Fatal("a failed cold index can never retry")
	} else if len(pagedResults(cmd)) != 1 {
		t.Fatal("retry did not issue a bounded index request")
	}
	if m.ensureTranscriptPages() != nil {
		t.Fatal("retry was duplicated before its reply")
	}
}

func TestReplayBackpressureDoesNotBecomeDocumentCorruption(t *testing.T) {
	m, replay, _ := pagedTranscriptModel(t, pagedUserCorpus(20))
	defer m.Close()
	m.replay = replay
	for i := 0; i < 4; i++ {
		m.applyPagedReply(commandResult{name: "transcript_page", requestSession: m.session,
			err: errors.New("native replay request queue is full (16 pending)")})
	}
	if replay.failed() || replay.failures != 0 {
		t.Fatalf("ordinary backpressure exhausted the corruption budget: %s", replay.failureReason())
	}
	if m.nextUIWake(time.Now()).IsZero() {
		t.Fatal("backpressure has no deferred retry wake")
	}
	if m.ensureTranscriptPages() != nil {
		t.Fatal("backpressure retry ignored its bounded delay")
	}
	m.replayRetryAt = time.Now().Add(-time.Second)
	m.ensureTranscriptPages()
	if !m.replayRetryAt.IsZero() {
		t.Fatal("an elapsed retry deadline kept the idle clock alive")
	}
}

func TestElapsedReplayRetryDoesNotSpinWhileIndexIsPending(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.replay = newPagedReplay()
	m.replayIndexPending = true
	m.replayRetryAt = time.Now().Add(-time.Second)
	if m.ensureTranscriptPages() != nil {
		t.Fatal("elapsed retry duplicated the pending index")
	}
	if !m.replayRetryAt.IsZero() || !m.nextUIWake(time.Now()).IsZero() {
		t.Fatal("a consumed retry deadline kept scheduling frames while awaiting the index")
	}
}

func TestInitialAttachRequestsBoundedReplay(t *testing.T) {
	m := newModel()
	defer m.Close()
	h := &pagedTestHost{session: "saved", revision: "100:1:0", corpus: pagedUserCorpus(2000), indexWindow: 400}
	m.host = h
	next, cmd := m.Update(commandResult{name: "runtime_state", payload: json.RawMessage(`{"session_id":"saved","status":"ready"}`)})
	m = next.(model)
	results := pagedResults(cmd)
	index := false
	for _, result := range results {
		if result.name == "session_transcript" {
			t.Fatal("production attach still requested the full-history reply")
		}
		if result.name == "transcript_index" {
			index = true
		}
	}
	if !index {
		t.Fatal("production attach did not request the bounded document index")
	}
	// Drive replies through the same Update seam as the CLI. UI timer commands
	// are irrelevant to corpus delivery; pagedResults extracts only host replies.
	for rounds := 0; len(results) > 0; rounds++ {
		if rounds > 100 {
			t.Fatal("paged attach did not settle")
		}
		var pending []commandResult
		for _, result := range results {
			next, follow := m.Update(result)
			m = next.(model)
			pending = append(pending, pagedResults(follow)...)
		}
		results = pending
	}
	if len(m.transcript) != 2000 {
		t.Fatalf("index window became the entire history: got %d entries", len(m.transcript))
	}
	loaded := 0
	for _, source := range m.transcript {
		if source != "" {
			loaded++
		}
	}
	if loaded == 0 || loaded >= 2000 {
		t.Fatalf("expected a resident tail window, got %d bodies", loaded)
	}
}
