package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestWheelPresentsTheDocumentOnce(t *testing.T) {
	m := scrollWorkload("short_history")
	defer m.Close()
	before := m.presentation.mounts
	next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
	m = next.(model)
	_ = m.View()
	if got := m.presentation.mounts - before; got != 1 {
		t.Fatalf("one wheel event mounted the document %d times, want once", got)
	}
}

func TestPrewrappedViewportKeepsTheSameCellsWithoutSoftWrap(t *testing.T) {
	for _, width := range []int{16, 40, 108} {
		m := newModel()
		m.width, m.height, m.welcomeHidden = width, 36, true
		m.resize()
		m.appendUser(strings.Repeat("中文 👩‍💻 and text ", 80))
		m.appendAssistant("**bold** and `code`\n\n" + strings.Repeat("another long message 中文\n", 40))
		m.refreshTranscript()
		for _, delta := range []int{-3, -17, -60, 10, 1 << 20} {
			m.scrollTranscript(delta)
			m.viewport.SoftWrap = true
			wrapped := m.viewport.View()
			m.viewport.SoftWrap = false
			if got := m.viewport.View(); got != wrapped {
				t.Fatalf("prewrapped viewport changed cells at width %d after scroll %d", width, delta)
			}
		}
		m.Close()
	}
}

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
