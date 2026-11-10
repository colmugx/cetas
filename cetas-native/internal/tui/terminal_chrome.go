package tui

import (
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
)

// Terminal chrome emissions for Ghostty-class terminals: the OSC 2 window
// title follows the active workspace, and an unfocused turn completion
// becomes one OSC 9 desktop notification. Both ride tea.Raw beside the
// program-status report.

func (m *model) requestTitle() {
	title := "cetas"
	if base := filepath.Base(strings.TrimSpace(m.surface.cwd)); base != "" && base != "." && base != "/" {
		title = "cetas · " + base
	}
	if title != m.lastTitle {
		m.pendingTitle = title
	}
}

func (m *model) requestNotice(text string) {
	if !m.focused {
		m.pendingNotice = text
	}
}

// emitTerminalChrome flushes one pending title update and at most one
// notification per update pass.
func (m *model) emitTerminalChrome() tea.Cmd {
	var cmds []tea.Cmd
	if m.pendingTitle != "" && m.pendingTitle != m.lastTitle {
		title := m.pendingTitle
		m.lastTitle = title
		m.pendingTitle = ""
		cmds = append(cmds, tea.Raw("\x1b]2;"+strings.ReplaceAll(title, "\x1b", " ")+"\x07"))
	}
	if m.pendingNotice != "" {
		notice := m.pendingNotice
		m.pendingNotice = ""
		// The body is plain text from our own strings; strip ESC defensively
		// so a hostile path can never splice a second sequence.
		cmds = append(cmds, tea.Raw("\x1b]9;"+strings.ReplaceAll(notice, "\x1b", " ")+"\x07"))
	}
	return tea.Batch(cmds...)
}
