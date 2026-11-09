package tui

import (
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
	"strings"
)

// Keep err as a diagnostic for command callers, but never render it beside the
// draft. A state redraw must not append the same failure repeatedly.
func (m *model) presentErrorNotice() bool {
	if m.err == "" {
		m.presentedError = ""
		return false
	}
	if m.err == m.presentedError {
		return false
	}
	m.presentedError = m.err
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at := len(m.transcript)
	m.transcript = append(m.transcript, "● "+m.err)
	m.blocks[at] = transcriptui.Block{Kind: "error", Text: m.err}
	return true
}

func (m *model) appendUser(text string) {
	m.welcomeHidden = true
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	at := len(m.transcript)
	// Source remains compatible with copy/search; display comes from the block.
	m.transcript = append(m.transcript, "> "+text)
	m.blocks[at] = transcriptui.Block{Kind: "user", Text: text}
}

func (m model) renderNotice(b transcriptui.Block) string {
	role := "muted"
	prefix := ""
	if b.Kind == "error" {
		role = "error"
		prefix = "● "
	}
	lines := strings.Split(b.Text, "\n")
	for i, line := range lines {
		if i == 0 {
			line = prefix + line
		}
		lines[i] = " " + m.theme().Role(role, line)
	}
	return strings.Join(lines, "\n")
}
