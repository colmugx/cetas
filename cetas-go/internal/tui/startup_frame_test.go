package tui

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
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

func TestFailedBootstrapKeepsOriginalCauseWhenHostIsUnavailable(t *testing.T) {
	m := newModel()
	const cause = "native local owner: another Cetas runtime owns this home"
	next, _ := m.Update(bootResult{err: errors.New(cause)})
	m = next.(model)
	if m.err != cause || m.startupFailure != cause {
		t.Fatalf("startup error was lost: err=%q original=%q", m.err, m.startupFailure)
	}
	m.textarea.SetValue("hello")
	next, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if m.err != cause {
		t.Fatalf("Enter overwrote original startup cause: %q", m.err)
	}
	// A session picker must report the real startup problem as well.
	m.sessionPickerFetch("", sessionPickerFirst, 1)
	if m.startupFailure != cause {
		t.Fatalf("picker discarded startup failure: %q", m.startupFailure)
	}
}
