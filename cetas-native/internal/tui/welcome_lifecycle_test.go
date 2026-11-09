package tui

import (
	"context"
	"encoding/json"
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type welcomeSessionHost struct {
	testHost
	method string
}

func (h *welcomeSessionHost) Request(_ context.Context, method string, _ any) (json.RawMessage, error) {
	h.method = method
	return json.RawMessage(`{"session_id":"fresh","status":"ready"}`), nil
}

func TestNewSessionReturnsToWelcomeWithoutChangingRuntimeCommand(t *testing.T) {
	host := &welcomeSessionHost{}
	m := newModel()
	m.host = host
	next, _ := m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[{"kind":"user","text":"old work"}]}`)})
	m = next.(model)
	m.textarea.SetValue("/new")
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if cmd == nil {
		t.Fatal("/new did not request a session")
	}
	reply := cmd()
	if host.method != "switch_session" {
		t.Fatalf("frontend changed the runtime command: %q", host.method)
	}
	next, _ = m.Update(reply)
	m = next.(model)
	next, _ = m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[]}`)})
	m = next.(model)
	if !strings.Contains(ansi.Strip(m.View().Content), "Describe a task to begin.") {
		t.Fatal("/new was treated as resuming old work")
	}
}

func TestRuntimeTurnStartHidesWelcomeWithoutTypedPrompt(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"turn.started"}`))
	next, _ := m.Update(tea.WindowSizeMsg{Width: 108, Height: 36})
	m = next.(model)
	if len(m.regions().header) != 0 {
		t.Fatal("runtime-entered work retained welcome")
	}
	m.applyEvent(event(`{"type":"turn.completed","text":"finished"}`))
	next, _ = m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[]}`)})
	m = next.(model)
	if len(m.regions().header) != 0 {
		t.Fatal("completion/empty replay reopened welcome")
	}
}

func TestResumedSessionNeverReopensWelcome(t *testing.T) {
	for _, history := range []string{`{"items":[]}`, `{"items":[{"kind":"user","text":"saved task"},{"kind":"assistant","text":"saved reply"}]}`} {
		t.Run(history, func(t *testing.T) {
			m := newModel()
			m.host = &testHost{}
			m.width, m.height = 108, 36
			next, _ := m.Update(commandResult{name: "switch_session", payload: json.RawMessage(`{"session_id":"resumed","status":"ready"}`)})
			m = next.(model)
			if len(m.regions().header) != 0 {
				t.Fatal("resuming still displays welcome before replay")
			}
			for _, msg := range []tea.Msg{
				commandResult{name: "session_transcript", payload: json.RawMessage(history)},
				tea.BackgroundColorMsg{Color: color.RGBA{12, 12, 12, 255}},
				tea.ForegroundColorMsg{Color: color.RGBA{240, 240, 240, 255}},
				tea.WindowSizeMsg{Width: 40, Height: 12},
				tea.KeyPressMsg{Code: tea.KeyPgUp},
				tea.WindowSizeMsg{Width: 108, Height: 36},
			} {
				next, _ = m.Update(msg)
				m = next.(model)
				if len(m.regions().header) != 0 || strings.Contains(ansi.Strip(m.View().Content), "Describe a task") {
					t.Fatalf("%T reopened welcome for resumed session", msg)
				}
			}
			if strings.Contains(history, "saved task") && !strings.Contains(ansi.Strip(m.View().Content), "saved reply") {
				t.Fatal("hiding resumed welcome lost the saved conversation")
			}
		})
	}
}

func TestAutoRestoredHistoryIsWorkNotWelcome(t *testing.T) {
	for _, history := range []string{
		`{"items":[{"kind":"assistant","text":"saved reply"}]}`,
		`{"items":[{"kind":"reasoning","text":"saved thought"}]}`,
		`{"items":[{"kind":"tool","name":"read","result":"saved source"}]}`,
	} {
		m := newModel()
		m.host = &testHost{}
		next, _ := m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(history)})
		m = next.(model)
		if len(m.regions().header) != 0 {
			t.Fatalf("automatic history load left welcome pinned: %s", history)
		}
	}
}

func TestWorkingConversationHasNoFixedWelcomeRegion(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	next, _ := m.Update(tea.WindowSizeMsg{Width: 108, Height: 36})
	m = next.(model)
	if !strings.Contains(ansi.Strip(m.View().Content), "Describe a task to begin.") {
		t.Fatal("fresh empty workspace lost startup guidance")
	}
	m.textarea.SetValue("start working")
	next, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if len(m.regions().header) != 0 || m.regions().transcriptY != 0 {
		t.Fatalf("work still reserves a fixed welcome: %q", ansi.Strip(strings.Join(m.regions().header, "\n")))
	}
	if !strings.Contains(ansi.Strip(m.View().Content), "> start working") {
		t.Fatal("hiding welcome also hid the submitted user block")
	}
	for _, size := range [][2]int{{40, 12}, {108, 36}, {18, 6}} {
		next, _ = m.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
		m = next.(model)
		if len(m.regions().header) != 0 {
			t.Fatalf("resize recreated the hidden welcome at %v", size)
		}
	}
}
