package tui

import (
	"encoding/json"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/colmugx/cetas/cetas-native/internal/wire"
	"strings"
	"testing"
)

func TestBlockingQuestionQueueUpdatesDashboardAwaitingCount(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	for _, raw := range []string{
		`{"type":"ui.request","request_id":"ask-1","kind":"confirm","prompt":"Continue?"}`,
		`{"type":"ui.request","request_id":"ask-2","kind":"confirm","prompt":"Allow?"}`,
	} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); !strings.Contains(screen, "2 awaiting reply") {
		t.Fatalf("blocking requests absent from dashboard: %q", screen)
	}
	for i, raw := range []string{`{"type":"ui.dismiss","request_id":"ask-1"}`, `{"type":"ui.dismiss","request_id":"ask-2"}`} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
		screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
		if i == 0 && !strings.Contains(screen, "1 awaiting reply") || i == 1 && strings.Contains(screen, "awaiting reply") {
			t.Fatalf("dismissed blocking requests kept stale counts: %q", screen)
		}
	}
}

func TestTallAskDoesNotDiscardStatusbarDetails(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 24
	m.applyEvent(event(`{"type":"turn.started"}`))
	m.applyEvent(event(`{"type":"ui.render","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"model","value":"provider/model:high"},{"key":"permission","value":"yolo"},{"key":"5h","value":"42%"}]}}}`))
	raw, err := json.Marshal(map[string]any{"type": "ui.request", "request_id": "long-ask", "kind": "select", "prompt": "Allow operation?\n" + strings.Repeat("A paragraph describing the operation.\n\n", 30), "options": []string{"Allow", "Deny"}})
	if err != nil {
		t.Fatal(err)
	}
	next, _ := m.Update(eventBatchResult{events: []wire.Event{event(string(raw))}})
	m = next.(model)
	screen := ansi.Strip(m.View().Content)
	if !strings.Contains(screen, "yolo") || !strings.Contains(screen, "5h 42%") {
		t.Fatalf("ask consumed the statusbar detail row: %q", screen)
	}
	if m.regions().editorY >= 24 || len(strings.Split(screen, "\n")) > 24 {
		t.Fatal("protecting statusbar pushed the editor outside the terminal")
	}
}

func TestStatusbarEntriesKeepRuntimeProviderIdentity(t *testing.T) {
	m := newModel()
	m.width = 108
	m.height = 36
	for _, raw := range []string{`{"type":"session.snapshot","model":"provider/model","effort":"high","permission":"yolo"}`, `{"type":"ui.render","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"model","value":"model:high"},{"key":"permission","value":"yolo"}]}}}`} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
	}
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "provider/model:high") {
		t.Fatalf("status update erased actual selected provider: %q", screen)
	}
}

func TestRuntimeSnapshotCanClearEffortInRenderedDashboard(t *testing.T) {
	m := newModel()
	m.width = 108
	m.height = 36
	for _, raw := range []string{`{"type":"session.snapshot","model":"provider/model","effort":"high","permission":"yolo"}`, `{"type":"session.snapshot","effort":""}`} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
	}
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "provider/model") || !strings.Contains(screen, "yolo") || strings.Contains(screen, ":high") {
		t.Fatalf("stale model/permission dashboard: %q", screen)
	}
}
func TestQuestionAndChildEventsAppearInRenderedDashboard(t *testing.T) {
	m := newModel()
	m.width = 108
	m.height = 36
	events := []wire.Event{event(`{"type":"question.asked","question_id":"question-1","short_id":"@q1","question":"Continue?","kind":"confirm"}`), event(`{"type":"subagent.event","child_session":"child-1","parent_call":"call-1","kind":"explore","ev":{"type":"turn.started"}}`)}
	next, _ := m.Update(eventBatchResult{events: events})
	m = next.(model)
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "1 agent") || !strings.Contains(screen, "? 1 to answer") {
		t.Fatalf("received activity not presented in dashboard: %q", screen)
	}
	next, _ = m.Update(tea.WindowSizeMsg{Width: 40, Height: 24})
	m = next.(model)
	for _, line := range m.regions().dashboard {
		if ansi.StringWidth(line) > 40 {
			t.Fatalf("narrow dashboard overflow: %q", line)
		}
	}
}
