// Package composer adapts Bubbles' editor to the Cetas input contract.
// Rendering and input decoding remain Bubble Tea's responsibility.
package composer

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/textarea"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

type snapshot struct {
	text         string
	line, column int
}
type paste struct{ marker, text string }
type Model struct {
	textarea.Model
	undo         []snapshot
	history      []string
	historyIndex int
	draft        string
	pastes       []paste
	nextPaste    int
	ring         []string
	yankIndex    int
	beforeYank   *snapshot
}

func New() Model {
	t := textarea.New()
	t.Prompt = ""
	t.Placeholder = "Describe a task, or type /help"
	t.ShowLineNumbers = false
	t.SetVirtualCursor(false)
	t.CharLimit = 0
	t.DynamicHeight = true
	t.MinHeight = 1
	t.MaxHeight = 8
	t.MaxContentHeight = 1 << 30
	t.EndOfBufferCharacter = ' '
	t.KeyMap.InsertNewline.SetKeys("shift+enter", "ctrl+j")
	t.KeyMap.WordBackward.SetKeys("alt+left", "ctrl+left", "alt+b")
	t.KeyMap.WordForward.SetKeys("alt+right", "ctrl+right", "alt+f")
	t.KeyMap.DeleteWordBackward.SetKeys("ctrl+w", "alt+backspace")
	t.KeyMap.DeleteWordForward.SetKeys("alt+d", "alt+delete")
	// The composer is chromeless: no prompt glyph and no cursor-line wash.
	// The block cursor itself carries the caret; only the functional
	// selection highlight keeps a background.
	styles := t.Styles()
	styles.Focused.CursorLine = lipgloss.NewStyle()
	styles.Blurred.CursorLine = lipgloss.NewStyle()
	t.SetStyles(styles)
	return Model{Model: t, historyIndex: -1}
}
func (m Model) current() snapshot { return snapshot{m.Value(), m.Line(), m.Column()} }
func (m *Model) restore(s snapshot) {
	m.Model.SetValue(s.text)
	m.MoveToBegin()
	for i := 0; i < s.line; i++ {
		m.CursorDown()
	}
	m.SetCursorColumn(s.column)
}
func (m *Model) Reset() {
	m.Model.Reset()
	m.undo = nil
	m.pastes = nil
	m.historyIndex = -1
	m.draft = ""
	m.beforeYank = nil
}

// Submission expands only intact paste markers; editing/deleting a chip never
// silently submits a different visible value.
func (m Model) Submission() string {
	text := m.Value()
	for _, p := range m.pastes {
		text = strings.ReplaceAll(text, p.marker, p.text)
	}
	return text
}
func (m *Model) Remember(text string) {
	if text != "" && (len(m.history) == 0 || m.history[len(m.history)-1] != text) {
		m.history = append(m.history, text)
		if len(m.history) > 100 {
			m.history = append([]string(nil), m.history[len(m.history)-100:]...)
		}
	}
	m.historyIndex = -1
	m.draft = ""
}
func (m *Model) rememberUndo(s snapshot) {
	m.undo = append(m.undo, s)
	if len(m.undo) > 100 {
		m.undo = append([]snapshot(nil), m.undo[len(m.undo)-100:]...)
	}
}
func removed(before, after string) string {
	a, b := []rune(before), []rune(after)
	start := 0
	for start < len(a) && start < len(b) && a[start] == b[start] {
		start++
	}
	endA, endB := len(a), len(b)
	for endA > start && endB > start && a[endA-1] == b[endB-1] {
		endA--
		endB--
	}
	return string(a[start:endA])
}
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	if _, release := msg.(tea.KeyReleaseMsg); release {
		return m, nil
	}
	before := m.current()
	kill := false
	if k, ok := msg.(tea.KeyPressMsg); ok {
		switch k.String() {
		case "ctrl+-", "ctrl+_", "ctrl+z":
			if len(m.undo) > 0 {
				s := m.undo[len(m.undo)-1]
				m.undo = m.undo[:len(m.undo)-1]
				m.restore(s)
			}
			m.beforeYank = nil
			return m, nil
		case "up":
			if m.Line() == 0 && len(m.history) > 0 {
				if m.historyIndex < 0 {
					m.draft = m.Value()
					m.historyIndex = len(m.history)
				}
				if m.historyIndex > 0 {
					m.historyIndex--
					m.Model.SetValue(m.history[m.historyIndex])
					m.MoveToBegin()
				}
				return m, nil
			}
		case "down":
			if m.historyIndex >= 0 && m.Line() == m.LineCount()-1 {
				m.historyIndex++
				if m.historyIndex >= len(m.history) {
					m.Model.SetValue(m.draft)
					m.historyIndex = -1
				} else {
					m.Model.SetValue(m.history[m.historyIndex])
				}
				m.MoveToEnd()
				return m, nil
			}
		case "ctrl+y":
			if len(m.ring) > 0 {
				s := m.current()
				m.beforeYank = &s
				m.yankIndex = 0
				m.InsertString(m.ring[0])
				m.rememberUndo(before)
			}
			return m, nil
		case "alt+y":
			if m.beforeYank != nil && len(m.ring) > 1 {
				m.yankIndex = (m.yankIndex + 1) % len(m.ring)
				m.restore(*m.beforeYank)
				m.InsertString(m.ring[m.yankIndex])
			}
			return m, nil
		case "ctrl+w", "alt+backspace", "alt+d", "alt+delete", "ctrl+u", "ctrl+k":
			kill = true
		}
		m.beforeYank = nil
	}
	if p, ok := msg.(tea.PasteMsg); ok {
		text := strings.ReplaceAll(strings.ReplaceAll(p.Content, "\r\n", "\n"), "\r", "\n")
		if strings.Count(text, "\n") >= 10 {
			m.nextPaste++
			marker := fmt.Sprintf("[paste #%d +%d lines]", m.nextPaste, strings.Count(text, "\n")+1)
			m.pastes = append(m.pastes, paste{marker, text})
			m.InsertString(marker)
		} else {
			m.InsertString(text)
		}
		if m.Value() != before.text {
			m.rememberUndo(before)
		}
		return m, nil
	}
	var cmd tea.Cmd
	m.Model, cmd = m.Model.Update(msg)
	if m.Value() != before.text {
		m.rememberUndo(before)
		if kill {
			text := removed(before.text, m.Value())
			if text != "" {
				m.ring = append([]string{text}, m.ring...)
				if len(m.ring) > 20 {
					m.ring = m.ring[:20]
				}
			}
		}
	}
	return m, cmd
}
