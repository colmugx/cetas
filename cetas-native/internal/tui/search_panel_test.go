package tui

import (
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func TestSearchPanelOwnsFocusWithoutChangingComposer(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.transcript = []string{"needle first", "needle second"}
	m.reflow()
	m.textarea.SetValue("unfinished draft")
	next, _ := m.Update(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl | tea.ModShift})
	m = next.(model)
	if !m.surface.searchOpen {
		t.Fatal("search shortcut did not open panel")
	}
	for _, r := range "needle" {
		next, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
		m = next.(model)
	}
	if m.textarea.Value() != "unfinished draft" || len(m.searchHits) != 2 {
		t.Fatalf("search focus lost: %q %#v", m.textarea.Value(), m.searchHits)
	}
	if !strings.Contains(ansi.Strip(m.View().Content), "1/2") {
		t.Fatal("search panel does not show result position")
	}
	next, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if m.searchActive != 1 {
		t.Fatal("Enter did not advance search")
	}
	next, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	m = next.(model)
	if m.surface.searchOpen || m.textarea.Value() != "unfinished draft" {
		t.Fatal("Escape did not restore composer focus")
	}
}
