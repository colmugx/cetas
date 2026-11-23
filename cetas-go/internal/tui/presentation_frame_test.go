package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestPresentationLayoutTracksInputAndResize(t *testing.T) {
	m := newModel()
	defer m.Close()
	for _, message := range []tea.Msg{
		tea.WindowSizeMsg{Width: 108, Height: 36},
		tea.KeyPressMsg{Code: 'x', Text: "x"},
		tea.WindowSizeMsg{Width: 40, Height: 24},
	} {
		next, _ := m.Update(message)
		m = next.(model)
		view := m.View()
		if !strings.Contains(view.Content, "x") && m.textarea.Value() != "" {
			t.Fatal("cached layout lost the edited composer")
		}
		if view.Cursor == nil || view.Cursor.Y >= m.height || view.Cursor.X >= m.width {
			t.Fatalf("cached layout cursor is outside the resized frame: %#v", view.Cursor)
		}
	}
}
