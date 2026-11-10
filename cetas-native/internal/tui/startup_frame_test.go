package tui

import (
	"encoding/json"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/colmugx/cetas/cetas-native/internal/wire"
)

func TestStartupNoticeDoesNotCollapseWelcomeBeforeUserPrompt(t *testing.T) {
	m := newModel()
	for _, msg := range []tea.Msg{tea.WindowSizeMsg{Width: 108, Height: 36}, bootResult{host: &testHost{}}, eventBatchResult{events: []wire.Event{event(`{"type":"config.warning","field":"runtime","reason":"startup fixture warning"}`)}}, commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[]}`)}} {
		next, _ := m.Update(msg)
		m = next.(model)
	}
	screen := ansi.Strip(m.View().Content)
	if !strings.Contains(screen, "Describe a task to begin.") || !strings.Contains(screen, "startup fixture warning") {
		t.Fatalf("startup notification displaced the welcome guidance: %s", screen)
	}
	m.textarea.SetValue("a user task")
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if strings.Contains(ansi.Strip(m.View().Content), "Describe a task") {
		t.Fatal("first prompt did not collapse welcome")
	}
	next, _ = m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[]}`)})
	m = next.(model)
	if strings.Contains(ansi.Strip(m.View().Content), "startup fixture warning") {
		t.Fatal("a later replay carried a retired startup notification")
	}
}
