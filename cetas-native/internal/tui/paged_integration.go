package tui

import (
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// Index-request supervision bounds. A lost index reply used to latch
// `replayIndexPending` forever (pagination dead until the next switch), and a
// saturated replay queue retried every 100 ms without end.
const (
	// replayIndexTimeout is how long one cold transcript_index request may
	// stay unanswered before the latch is released and retried.
	replayIndexTimeout = 10 * time.Second
	// replayIndexTimeoutBudget caps deadline retries before pagination gives
	// up with a visible error instead of looping.
	replayIndexTimeoutBudget = 3
	// replayBackpressureBudget caps the 100 ms replay-queue retries.
	replayBackpressureBudget = 10
)

// A persisted revision is not a request generation: a same-session restart has
// no revision yet, and its old index may still complete. Tag every command,
// including commands inside a Batch, before the asynchronous host call runs.
func replayCommand(cmd tea.Cmd, generation uint64) tea.Cmd {
	if cmd == nil {
		return nil
	}
	return func() tea.Msg {
		switch message := cmd().(type) {
		case commandResult:
			message.replayGeneration = generation
			return message
		case tea.BatchMsg:
			for i, child := range message {
				message[i] = replayCommand(child, generation)
			}
			return message
		default:
			return message
		}
	}
}

// markIndexPending arms the one-outstanding-cold-index latch together with
// its deadline.
func (m *model) markIndexPending() {
	m.replayIndexPending = true
	m.replayIndexSince = time.Now()
}

func (m *model) startPagedReplay() tea.Cmd {
	m.cancelPagedCopy()
	m.replayGeneration++
	m.replayRetryAt = time.Time{}
	m.replayIndexTimeouts = 0
	m.replayBackpressure = 0
	m.replay = newPagedReplay()
	cmd := m.replay.start(m)
	if cmd != nil {
		m.markIndexPending()
	} else {
		m.replayIndexPending = false
	}
	return replayCommand(cmd, m.replayGeneration)
}

func (m *model) applyPagedReply(result commandResult) (tea.Cmd, bool) {
	switch result.name {
	case "transcript_index", "transcript_page", "transcript_source":
		if result.replayGeneration != m.replayGeneration {
			return nil, true
		}
		if result.requestSession != "" && result.requestSession != m.session {
			return nil, true
		}
		if m.replay == nil {
			return nil, true
		}
		if result.requestRevision != "" && m.replay.revision != "" && result.requestRevision != m.replay.revision {
			return nil, true
		}
		if result.name == "transcript_index" {
			m.replayIndexPending = false
			m.replayIndexSince = time.Time{}
		}
		message, _, _, failed := pagedError(result.payload)
		if result.err != nil {
			message, failed = result.err.Error(), true
		}
		if failed && strings.HasPrefix(message, "native replay request queue is full (") {
			// Backpressure is not a corrupt journal. Keep the error observable,
			// release the failed request bookkeeping and retry on one demand
			// wake — but only a bounded number of times.
			m.replayBackpressure++
			if m.replayBackpressure > replayBackpressureBudget {
				m.err = result.name + ": " + message + " (gave up after " +
					strconv.Itoa(replayBackpressureBudget) + " retries)"
				m.replay.releaseInflight()
				m.replayRetryAt = time.Time{}
				return nil, true
			}
			m.err = result.name + ": " + message
			m.replay.releaseInflight()
			m.replayRetryAt = time.Now().Add(100 * time.Millisecond)
			return nil, true
		}
	}
	cmd, handled := m.replay.apply(m, result)
	if cmd != nil && !m.replay.indexed {
		m.markIndexPending()
	}
	return replayCommand(cmd, m.replayGeneration), handled
}

func (m *model) ensureTranscriptPages() tea.Cmd {
	if !m.replayRetryAt.IsZero() {
		if time.Now().Before(m.replayRetryAt) {
			return nil
		}
		m.replayRetryAt = time.Time{}
	}
	if m.replayIndexPending {
		// A cold index that never answers must not wedge pagination until the
		// next switch: release the latch and re-probe, then give up visibly.
		if !m.replayIndexSince.IsZero() && time.Since(m.replayIndexSince) > replayIndexTimeout {
			m.replayIndexPending = false
			m.replayIndexSince = time.Time{}
			if m.replay != nil {
				m.replay.releaseInflight()
			}
			m.replayIndexTimeouts++
			if m.replayIndexTimeouts > replayIndexTimeoutBudget {
				m.err = "transcript_index timed out " + strconv.Itoa(replayIndexTimeoutBudget) +
					" times; transcript pagination disabled until the next session switch"
				return nil
			}
			m.err = "transcript index timed out; retrying"
		} else {
			// Exactly one cold index can be outstanding.
			return nil
		}
	}
	if m.replay == nil {
		return nil
	}
	cmd := m.replay.ensure(m)
	if cmd != nil && !m.replay.indexed {
		m.markIndexPending()
	}
	return replayCommand(cmd, m.replayGeneration)
}
