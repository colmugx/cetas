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

// The frame-equality oracle: whenever the snapshot fast path is armed, the
// cached frame must be byte-identical to a fresh render of the same model.
// A mismatch means some path mutated presentation-affecting state without
// invalidating the snapshot, so View() would paint a stale frame forever.
func TestCachedViewMatchesFreshRender(t *testing.T) {
	m := newModel()
	defer m.Close()
	states := map[string]func(*model){
		"window sized": func(m *model) { m.width, m.height = 108, 36 },
		"transcript mounted": func(m *model) {
			m.appendUser("oracle question")
			m.appendAssistant("**oracle** answer")
			m.refreshTranscript()
		},
		"streaming in flight": func(m *model) { m.streaming = "partial oracle stream"; m.refreshTranscript() },
	}
	order := []string{"window sized", "transcript mounted", "streaming in flight"}
	for _, name := range order {
		states[name](&m)
		next, _ := m.Update(nil)
		m = next.(model)
		if m.presentation.snapshot == nil || m.presentation.layout == nil {
			t.Fatalf("state %q did not arm the snapshot fast path", name)
		}
		cached := m.View().Content
		m.presentation.snapshot = nil
		if fresh := m.renderView().Content; cached != fresh {
			t.Fatalf("state %q: cached frame diverged from a fresh render\n--- cached ---\n%s\n--- fresh ---\n%s", name, cached, fresh)
		}
	}
	// The typed picker overlay is the one state whose panel render is
	// memoized separately; the snapshot must still match a fresh compose.
	host := &sessionCatalogHost{total: 5, cwd: "/workspace/demo"}
	m.host = host
	m = openTypedSessionPicker(t, &m)
	if m.presentation.snapshot == nil || m.presentation.layout == nil {
		t.Fatal("picker state did not arm the snapshot fast path")
	}
	cached := m.View().Content
	m.presentation.snapshot = nil
	if fresh := m.renderView().Content; cached != fresh {
		t.Fatal("picker state: cached frame diverged from a fresh render")
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
