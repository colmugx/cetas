package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

var frameSnapshotSink tea.View

func TestPresentedViewCanBeReadWithoutRebuildingTheFrame(t *testing.T) {
	m := newModel()
	defer m.Close()
	next, _ := m.Update(tea.WindowSizeMsg{Width: 108, Height: 36})
	m = next.(model)
	before := m.View()
	allocs := testing.AllocsPerRun(20, func() { frameSnapshotSink = m.View() })
	if allocs != 0 {
		t.Fatalf("unchanged View rebuilt presentation: %.0f allocations/read", allocs)
	}
	if !before.AltScreen || before.MouseMode != tea.MouseModeCellMotion || before.Content != frameSnapshotSink.Content {
		t.Fatal("cached View lost content or terminal mode")
	}
}

func TestPresentedViewFollowsInputResizeAndDirectDocumentChanges(t *testing.T) {
	m := newModel()
	defer m.Close()
	next, _ := m.Update(tea.WindowSizeMsg{Width: 108, Height: 36})
	m = next.(model)
	next, _ = m.Update(tea.KeyPressMsg{Code: 'x', Text: "snapshot-input"})
	m = next.(model)
	if !strings.Contains(m.View().Content, "snapshot-input") {
		t.Fatal("cached frame hid editor input")
	}
	next, _ = m.Update(tea.WindowSizeMsg{Width: 70, Height: 24})
	m = next.(model)
	if len(strings.Split(m.View().Content, "\n")) != 24 {
		t.Fatal("cached frame kept pre-resize geometry")
	}
	m.appendUser("direct-document-change")
	m.refreshTranscript()
	if !strings.Contains(m.View().Content, "direct-document-change") {
		t.Fatal("direct document mount kept an obsolete snapshot")
	}
}
