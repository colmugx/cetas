package tui

import (
	tea "charm.land/bubbletea/v2"
	"strings"
)

func (m model) completing() bool {
	return m.modalRequestID == "" && (m.modal == "slash" || m.modal == "files" || m.modal == "skills")
}
func (m *model) closeCompletion() {
	m.modal = ""
	m.modalItems = nil
	m.modalValues = nil
	m.modalIndex = 0
}
func completionAtEnd(value string) (prefix, token string) {
	at := strings.LastIndexAny(value, "@$")
	if at >= 0 && (at == 0 || strings.ContainsAny(value[at-1:at], " \t\n")) && !strings.ContainsAny(value[at:], " \t\n") {
		return value[:at], value[at:]
	}
	return "", ""
}
func (m *model) autocomplete() tea.Cmd {
	if m.modal != "" && !m.completing() {
		return nil
	}
	value := m.textarea.Value()
	if strings.HasPrefix(value, "/") {
		choices := m.commandSuggestions(value)
		if len(choices) > 0 {
			selected := ""
			if m.modalIndex < len(m.modalValues) {
				selected = m.modalValues[m.modalIndex]
			}
			m.modal = "slash"
			m.modalItems = nil
			m.modalValues = nil
			m.modalIndex = 0
			for i, c := range choices {
				m.modalItems = append(m.modalItems, c.label)
				m.modalValues = append(m.modalValues, c.insert)
				if c.insert == selected {
					m.modalIndex = i
				}
			}
		} else if m.completing() {
			m.closeCompletion()
		}
		return nil
	}
	prefix, token := completionAtEnd(value)
	if token == "" {
		if m.completing() {
			m.closeCompletion()
		}
		m.completionToken = ""
		return nil
	}
	if m.host == nil {
		return nil
	}
	if token == m.completionToken && prefix == m.completionPrefix {
		return nil
	}
	if m.completing() {
		m.closeCompletion()
	}
	m.completionPrefix = prefix
	m.completionToken = token
	command := "skills"
	args := map[string]any{}
	if token[0] == '@' {
		command = "file_search"
		args["q"] = token[1:]
	}
	return requestAs(m.host, "complete:"+command+":"+value, command, args)
}
