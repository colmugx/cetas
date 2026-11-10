package tui

import (
	"encoding/json"
	"errors"
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

// One refused read is a retryable condition, not an event: the document keeps
// paging and the transcript stays free of noise. A persisting refusal still
// becomes visible once the bounded budget runs out — that is
// TestPagedReplayStallsAfterRepeatedErrors.
func TestTransientReplayReadFailureStaysQuietAndRetryable(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "saved"
	m.replay = newPagedReplay()
	m.replay.session = "saved"
	next, _ := m.Update(commandResult{name: "transcript_index", requestSession: "saved", err: errors.New("fixture unreadable")})
	m = next.(model)
	if m.presentedError != "" {
		t.Fatalf("one refused read reached the transcript as a notice: %q", m.presentedError)
	}
	if m.replay.stalled {
		t.Fatal("one refused read stalled pagination")
	}
	if m.replay.failures != 1 {
		t.Fatalf("the failure was not counted against the stall budget: %d", m.replay.failures)
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
