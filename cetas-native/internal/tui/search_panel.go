package tui

import (
	tea "charm.land/bubbletea/v2"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
	"strings"
)

func (m *model) searchPanelKey(msg tea.KeyPressMsg) bool {
	if m.modal != "" || m.modalRequestID != "" {
		return false
	}
	key := msg.String()
	if key == "ctrl+shift+f" {
		m.surface.searchOpen = !m.surface.searchOpen
		if m.surface.searchOpen {
			m.surface.searchInput = m.searchQuery
		}
		return true
	}
	if !m.surface.searchOpen {
		return false
	}
	switch key {
	case "esc":
		m.surface.searchOpen = false
	case "enter", "ctrl+g":
		m.navigateTranscriptSearch(false)
	case "shift+enter", "ctrl+shift+g":
		m.navigateTranscriptSearch(true)
	case "backspace":
		value := []rune(m.surface.searchInput)
		if len(value) > 0 {
			m.surface.searchInput = string(value[:len(value)-1])
			m.findTranscript(m.surface.searchInput)
		}
	default:
		if msg.Text != "" {
			m.surface.searchInput += ui.Clean(msg.Text)
			m.findTranscript(m.surface.searchInput)
		}
	}
	return true
}

func (m model) paintSearchPanel(lines []string, width, height int) []string {
	if !m.surface.searchOpen || width < 4 || height < 3 || m.modalRequestID != "" || m.modal != "" {
		return lines
	}
	pw := min(width-2, max(32, width*40/100))
	pw = max(2, pw)
	inner := pw - 2
	result := ""
	if m.surface.searchInput != "" {
		result = "No matches"
		if len(m.searchHits) > 0 {
			result = fmt.Sprintf("%d/%d", m.searchActive+1, len(m.searchHits))
		}
	}
	result = ansi.Truncate(result, max(0, inner-3), "")
	suffix := ""
	if result != "" {
		suffix = " " + result + " "
	}
	input := ansi.Truncate("> "+ui.Clean(m.surface.searchInput), max(0, inner-ansi.StringWidth(suffix)), "")
	content := input + strings.Repeat(" ", max(0, inner-ansi.StringWidth(input)-ansi.StringWidth(suffix))) + suffix
	controls := "↑ Shift+Enter · ↓ Enter"
	if ansi.StringWidth(controls)+2 > inner {
		controls = "↑ ↓"
	}
	footer := strings.Repeat("─", inner)
	if ansi.StringWidth(controls)+2 <= inner {
		footer = strings.Repeat("─", inner-ansi.StringWidth(controls)-2) + " " + controls + " "
	}
	panel := []string{"┌" + strings.Repeat("─", inner) + "┐", "│" + content + "│", "└" + footer + "┘"}
	x, y := max(0, width-pw-1), 1
	out := append([]string(nil), lines...)
	for len(out) < min(height, y+len(panel)) {
		out = append(out, strings.Repeat(" ", width))
	}
	for row, line := range panel {
		if y+row >= len(out) {
			break
		}
		base := ui.Pad(out[y+row], width)
		out[y+row] = ansi.Cut(base, 0, x) + line + ansi.Cut(base, x+pw, width)
	}
	return out
}
