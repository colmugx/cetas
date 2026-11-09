package tui

import (
	"encoding/json"
	"fmt"
	"image/color"
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

// Exercise the real shell composition, not just Welcome's isolated fixture:
// boot, first window report, late OSC colours and subsequent resizing may all
// arrive in either order. A guidance row must not overwrite the editor.
func TestStartupGuidanceHasOneRegionAcrossMessageOrders(t *testing.T) {
	for _, size := range [][2]int{{108, 36}, {80, 24}, {40, 24}, {24, 12}} {
		for _, bootFirst := range []bool{false, true} {
			t.Run(fmt.Sprint(size, bootFirst), func(t *testing.T) {
				m := newModel()
				msgs := []tea.Msg{tea.WindowSizeMsg{Width: size[0], Height: size[1]}, bootResult{host: &testHost{}}}
				if bootFirst {
					msgs[0], msgs[1] = msgs[1], msgs[0]
				}
				msgs = append(msgs, tea.ForegroundColorMsg{Color: color.RGBA{240, 240, 240, 255}}, tea.BackgroundColorMsg{Color: color.RGBA{12, 12, 12, 255}})
				for _, msg := range msgs {
					next, _ := m.Update(msg)
					m = next.(model)
					screen := m.View().Content
					rows := strings.Split(screen, "\n")
					w, h := m.dimensions()
					if len(rows) > h {
						t.Fatalf("frame taller than terminal: %d>%d", len(rows), h)
					}
					for _, line := range rows {
						if ansi.StringWidth(line) > w {
							t.Fatalf("frame overflow: %q", line)
						}
					}
					r := m.regions()
					if r.editorY >= h {
						t.Fatal("editor cursor laid out below screen")
					}
				}
				w, h := m.dimensions()
				screen := ansi.Strip(m.View().Content)
				if w >= 40 && h >= 22 && strings.Count(screen, "Describe a task") != 1 {
					t.Fatalf("welcome guidance was lost or duplicated: %q", screen)
				}
				if strings.Contains(strings.Join(m.regions().status, "\n"), "ready") {
					t.Fatal("idle ready still takes an extra status row")
				}
			})
		}
	}
}
