package tui

import (
	"strings"

	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
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
	// Runtime diagnostics flow into the terminal verbatim: the same SGR
	// allowlist as tool results keeps hostile sequences out of the screen.
	safe := ui.SanitizeSGR(m.err)
	at := len(m.transcript)
	m.transcript = append(m.transcript, "● "+safe)
	m.blocks[at] = transcriptui.Block{Kind: "error", Text: safe}
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
