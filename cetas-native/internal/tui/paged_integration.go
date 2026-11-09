package tui

import (
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
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

func (m *model) startPagedReplay() tea.Cmd {
	m.cancelPagedCopy()
	m.replayGeneration++
	m.replayRetryAt = time.Time{}
	m.replay = newPagedReplay()
	cmd := m.replay.start(m)
	m.replayIndexPending = cmd != nil
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
		}
		message, _, _, failed := pagedError(result.payload)
		if result.err != nil {
			message, failed = result.err.Error(), true
		}
		if failed && strings.HasPrefix(message, "native replay request queue is full (") {
			// Backpressure is not a corrupt journal. Keep the error observable,
			// release the failed request bookkeeping and retry on one demand wake,
			// not in an immediate command/error loop or the corruption budget.
			m.err = result.name + ": " + message
			m.replay.releaseInflight()
			m.replayRetryAt = time.Now().Add(100 * time.Millisecond)
			return nil, true
		}
		if failed && message != "stale transcript revision" {
			m.err = result.name + ": " + message
		}
	}
	cmd, handled := m.replay.apply(m, result)
	if cmd != nil && !m.replay.indexed {
		m.replayIndexPending = true
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
	if m.replay == nil || m.replayIndexPending {
		// Exactly one cold index can be outstanding. Once an error settles it,
		// ensure may retry under the adapter's existing finite failure budget.
		return nil
	}
	cmd := m.replay.ensure(m)
	if cmd != nil && !m.replay.indexed {
		m.replayIndexPending = true
	}
	return replayCommand(cmd, m.replayGeneration)
}
