package tui

import (
	"encoding/json"
	"fmt"
	transcriptui "github.com/colmugx/cetas/cetas-go/internal/tui/transcript"
)

type transcriptItem struct {
	Kind      string          `json:"kind"`
	Text      string          `json:"text"`
	Name      string          `json:"name"`
	CallID    string          `json:"callId"`
	Status    string          `json:"status"`
	Arguments json.RawMessage `json:"args"`
	Result    string          `json:"result"`
}

func (m *model) restoreTranscript(raw json.RawMessage) {
	var payload struct {
		Items   []transcriptItem `json:"items"`
		Context json.RawMessage  `json:"context"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		m.err = "invalid session transcript: " + err.Error()
		return
	}
	// Startup diagnostics arrive before the initial history request completes.
	// They are live UI facts, not persisted session rows; replay must not erase
	// them before Bubble Tea's renderer has even had a chance to paint them.
	// Only the initial replay carries them forward, never a session switch or
	// rewind (those must retire the previous presentation).
	var startupNotices []transcriptui.Block
	if !m.initialReplayLoaded {
		for at := range m.transcript {
			if b := m.blocks[at]; b.Kind == "notice" || b.Kind == "error" {
				startupNotices = append(startupNotices, b)
			}
		}
	}
	m.initialReplayLoaded = true
	m.surface.notices = nil
	m.fragments = nil
	m.clearTranscriptSearch()
	m.resetVirtualTranscript()
	m.transcript = nil
	m.markdownRaw = nil
	m.markdownCache.reset()
	m.toolIndex = map[string]int{}
	m.blocks = map[int]transcriptui.Block{}
	pendingReasoning := ""
	for _, row := range payload.Items {
		switch row.Kind {
		case "user":
			// Replay and a typed prompt must produce the identical row: the
			// parent reducer owns the user block (source + full-width surface),
			// so replay delegates instead of re-implementing a raw echo.
			if row.Text != "" {
				m.appendUser(row.Text)
			}
		case "assistant":
			saved := m.reasoning
			m.reasoning = pendingReasoning
			switch {
			case row.Text != "":
				m.appendAssistant(row.Text)
			case pendingReasoning != "":
				// A reasoning-only message still owns a block, in the same place
				// the live stream showed it: before the answer that follows.
				m.appendThinking(pendingReasoning)
			}
			m.reasoning = saved
			pendingReasoning = ""
		case "reasoning":
			pendingReasoning += row.Text
		case "tool":
			if pendingReasoning != "" {
				m.appendThinking(pendingReasoning)
				pendingReasoning = ""
			}
			at := len(m.transcript)
			state := "running"
			switch row.Status {
			case "done":
				state = "succeeded"
			case "error":
				state = "failed"
			}
			m.transcript = append(m.transcript, "• "+row.Name)
			m.blocks[at] = transcriptui.Block{Kind: "tool", CallID: row.CallID, Name: row.Name, State: state, Arguments: row.Arguments, Text: row.Result}
			if row.CallID != "" {
				m.toolIndex[row.CallID] = at
			}
			m.addHiddenSource(at, row.Result)
		}
	}
	if pendingReasoning != "" {
		m.appendThinking(pendingReasoning)
	}
	// Restoring actual conversation content is already work, even if the
	// history has no user row. Startup diagnostics alone remain onboarding.
	if len(m.transcript) > 0 {
		m.welcomeHidden = true
	}
	for _, b := range startupNotices {
		at := len(m.transcript)
		m.transcript = append(m.transcript, "● "+b.Text)
		m.blocks[at] = b
	}
	m.refreshTranscript()
}
func (m *model) appendThinking(text string) {
	if text == "" {
		return
	}
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at := len(m.transcript)
	m.transcript = append(m.transcript, fmt.Sprintf("💭 thought · %d lines", lenLines(text)))
	m.blocks[at] = transcriptui.Block{Kind: "thinking", Text: text}
	m.addHiddenSource(at, "Thinking: "+text)
}
func lenLines(s string) int {
	n := 1
	for _, r := range s {
		if r == '\n' {
			n++
		}
	}
	return n
}
func (m *model) flushAssistant() {
	if m.streaming != "" {
		m.appendAssistant(m.streaming)
	} else if m.reasoning != "" {
		m.appendThinking(m.reasoning)
	}
	m.streaming = ""
	m.reasoning = ""
}
