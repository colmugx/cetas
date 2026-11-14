package tui

import (
	tea "charm.land/bubbletea/v2"
	"testing"
)

func TestShellRoutesTranscriptMouseThroughRealUpdate(t *testing.T) {
	m := newModel()
	m.width, m.height = 40, 12
	m.resize()
	m.transcript = []string{"abcdef"}
	m.reflow()
	copied := ""
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }
	y := m.regions().transcriptY
	for _, msg := range []tea.Msg{tea.MouseClickMsg{X: 1, Y: y, Button: tea.MouseLeft}, tea.MouseMotionMsg{X: 4, Y: y, Button: tea.MouseLeft}, tea.MouseReleaseMsg{X: 4, Y: y, Button: tea.MouseNone}} {
		next, _ := m.Update(msg)
		m = next.(model)
	}
	if copied != "bcde" {
		t.Fatalf("shell did not route selection/copy: %q", copied)
	}
}
