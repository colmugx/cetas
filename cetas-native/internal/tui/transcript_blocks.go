package tui

import (
	"charm.land/lipgloss/v2"
	"encoding/json"
	"fmt"
	"sort"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
	"strings"
	"time"
)

type toolFragment struct{ ID, Name, Text string }

func (m *model) projectToolEvent(kind string, raw json.RawMessage) bool {
	if !strings.HasPrefix(kind, "tool.") {
		return false
	}
	if kind == "tool.args_delta" {
		m.projectToolFragment(raw)
		return true
	}
	switch kind {
	case "tool.started", "tool.approved", "tool.started_run", "tool.completed":
	default:
		return false
	}
	var frame struct {
		ID          string                    `json:"tool_call_id"`
		Name        string                    `json:"tool_name"`
		State       string                    `json:"state"`
		Phase       string                    `json:"phase"`
		Arguments   json.RawMessage           `json:"arguments"`
		Result      json.RawMessage           `json:"result"`
		IsError     bool                      `json:"is_error"`
		Structured  json.RawMessage           `json:"structured"`
		Attachments []transcriptui.Attachment `json:"attachments"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		m.err = "invalid tool event: " + err.Error()
		return true
	}
	if frame.ID == "" {
		m.err = "tool event missing tool_call_id"
		return true
	}
	if activity := m.activityForCall(frame.ID); activity != nil && activity.background && activity.taskID != "" {
		return true
	}
	if m.toolIndex == nil {
		m.toolIndex = map[string]int{}
	}
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at, exists := m.toolIndex[frame.ID]
	if !exists {
		m.flushAssistant()
		at = len(m.transcript)
		m.toolIndex[frame.ID] = at
		m.transcript = append(m.transcript, "• "+frame.Name+" …")
		m.blocks[at] = transcriptui.Block{Kind: "tool", CallID: frame.ID, Name: frame.Name, State: "pending", Arguments: frame.Arguments}
	}
	b := m.blocks[at]
	if transcriptui.ParseToolPhase(b.State).Terminal() {
		// Settled rows are immutable, including rows whose wire phase fell
		// outside the known vocabulary: a stray phase must latch the row, not
		// keep it mutating (and animating) forever.
		return true
	}
	if frame.Name != "" {
		b.Name = frame.Name
	}
	if len(frame.Arguments) > 0 {
		b.Arguments = frame.Arguments
	}
	switch kind {
	case "tool.started":
		if b.State == "streaming" {
			b.State = "pending"
		}
	case "tool.approved":
		if b.State != "running" {
			b.State = "approved"
		}
	case "tool.started_run":
		b.State = "running"
		if b.Started.IsZero() {
			b.Started = time.Now()
		}
	case "tool.completed":
		b.State = frame.Phase
		if b.State == "" {
			b.State = frame.State
		}
		if b.State == "" {
			b.State = "succeeded"
			if frame.IsError {
				b.State = "failed"
			}
		}
		b.Text = toolResultText(frame.Result)
		if len(frame.Structured) > 0 && frame.Structured[0] == '{' {
			if err := json.Unmarshal(frame.Structured, &b.Structured); err != nil {
				m.err = "invalid tool summary: " + err.Error()
			}
		}
		b.Attachments = frame.Attachments
		b.Finished = time.Now()
		marker := "✓"
		if frame.IsError {
			marker = "✗"
		}
		m.transcript[at] = "• " + b.Name + " " + marker
		if m.showTools && b.Text != "" {
			m.transcript[at] += "\n" + b.Text
		}
		m.addHiddenSource(at, b.Text)
	}
	m.blocks[at] = b
	m.invalidateTranscriptBlock(at)
	return true
}
func (m *model) projectToolFragment(raw json.RawMessage) {
	var f struct {
		Index int    `json:"index"`
		ID    string `json:"id"`
		Name  string `json:"name"`
		Delta string `json:"delta"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		m.err = "invalid tool argument delta: " + err.Error()
		return
	}
	if m.fragments == nil {
		m.fragments = map[int]toolFragment{}
	}
	fragment := m.fragments[f.Index]
	if f.ID != "" && fragment.ID != f.ID {
		fragment = toolFragment{ID: f.ID}
	}
	if f.Name != "" {
		fragment.Name = f.Name
	}
	fragment.Text += f.Delta
	m.fragments[f.Index] = fragment
	// Fragment indices are monotonic per stream, so evicting the smallest
	// keys drops the longest-settled streams. A late delta for an evicted
	// index simply re-creates its fragment — degraded, never wrong.
	if len(m.fragments) > toolFragmentCap {
		keys := make([]int, 0, len(m.fragments))
		for key := range m.fragments {
			keys = append(keys, key)
		}
		sort.Ints(keys)
		for _, key := range keys[:len(keys)-toolFragmentCap] {
			delete(m.fragments, key)
		}
	}
	id := fragment.ID
	if id == "" {
		return
	} // An unattributed fragment is held until its identity arrives.
	if m.toolIndex == nil {
		m.toolIndex = map[string]int{}
	}
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at, exists := m.toolIndex[id]
	if !exists {
		m.flushAssistant()
		at = len(m.transcript)
		m.toolIndex[id] = at
		m.transcript = append(m.transcript, "• "+fragment.Name+" …")
	}
	b := m.blocks[at]
	if b.State != "" && b.State != "streaming" {
		return
	}
	b.Kind = "tool"
	b.CallID = id
	b.Name = fragment.Name
	b.State = "streaming"
	b.Arguments = json.RawMessage(fragment.Text)
	m.blocks[at] = b
	m.invalidateTranscriptBlock(at)
}
func (m *model) renderBlock(index int) (string, bool) {
	b, ok := m.blocks[index]
	if !ok || b.Kind == "assistant" {
		return "", false
	}
	if b.Kind == "notice" || b.Kind == "error" {
		return m.renderNotice(b), true
	}
	if b.Kind == "image" && b.ImageID > 0 {
		for _, layout := range m.kittyImages {
			if layout.id == b.ImageID {
				return kittyPlaceholderLines(layout.id, layout.cols, layout.rows), true
			}
		}
	}
	theme := m.theme()
	role := func(name string) func(string) string { return func(s string) string { return theme.Role(name, s) } }
	muted := role("muted")
	if b.Kind == "thinking" {
		muted = m.thinkingStyle
	}
	rendered := b.Render(transcriptui.Options{Width: m.viewport.Width(), ToolsExpanded: m.showTools, ThinkingExpanded: m.showThinking, Now: time.Now(), Styles: transcriptui.Styles{Dim: func(s string) string { return lipgloss.NewStyle().Faint(true).Render(s) }, ToolTitle: func(s string) string { return lipgloss.NewStyle().Bold(true).Render(theme.Role("warning", s)) }, Muted: muted, Pending: role("warning"), Success: role("success"), Error: role("error"), User: func(s string) string { return theme.Surface("user", s) }}})
	return m.decorateAgentCall(b.CallID, rendered), true
}
func (m model) thinkingStyle(text string) string {
	return lipgloss.NewStyle().Italic(true).Render(m.theme().Role("muted", text))
}

func (m *model) decorateAssistant(index int, content string) string {
	if b, ok := m.blocks[index]; ok && b.Reasoning != "" {
		thinking := transcriptui.Block{Kind: "thinking", Text: b.Reasoning}
		content = thinking.Render(transcriptui.Options{Width: m.viewport.Width(), ThinkingExpanded: m.showThinking, Styles: transcriptui.Styles{Muted: m.thinkingStyle}}) + "\n" + content
	}
	return content
}
func (m *model) protocolNotice(text string) {
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at := len(m.transcript)
	m.transcript = append(m.transcript, fmt.Sprintf("● %s", text))
	m.blocks[at] = transcriptui.Block{Kind: "notice", Text: text}
}
