package main

import (
	"context"
	"encoding/json"
	"fmt"
	"image/color"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/colmugx/cetas/cetas-native/harness"
	"github.com/colmugx/cetas/cetas-native/internal/tui"
)

type observedShell struct {
	tea.Model
	frames chan string
}

func (m observedShell) Close() {
	if presentation, ok := m.Model.(interface{ Close() }); ok {
		presentation.Close()
	}
}

func (m observedShell) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	next, cmd := m.Model.Update(msg)
	m.Model = next
	m.frames <- next.View().Content
	return m, cmd
}

// Real compatible provider -> MoonBit observer -> C queue -> harness -> public
// Bubble Tea Update/View. PTY smokes separately verify real terminal key bytes.
func TestRealRuntimeMessagesReachShellPresentation(t *testing.T) {
	home, workspace := t.TempDir(), t.TempDir()
	t.Chdir(workspace)
	t.Setenv("CETAS_HOME", home)
	if err := os.WriteFile("sample.txt", []byte("fixture source\n"), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []struct {
				Role string `json:"role"`
				Call string `json:"tool_call_id"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		complete := false
		for _, message := range req.Messages {
			if message.Role == "tool" && message.Call == "visual-read" {
				complete = true
			}
		}
		w.Header().Set("Content-Type", "text/event-stream")
		send := func(delta any, finish any) {
			raw, _ := json.Marshal(map[string]any{"id": "visual", "object": "chat.completion.chunk", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}})
			fmt.Fprintf(w, "data: %s\n\n", raw)
			w.(http.Flusher).Flush()
		}
		if complete {
			send(map[string]any{"content": "Final fixture answer."}, nil)
			send(map[string]any{}, "stop")
		} else {
			send(map[string]any{"reasoning_content": "Inspect evidence.\nRead the local file."}, nil)
			time.Sleep(150 * time.Millisecond)
			send(map[string]any{"content": "## Fixture heading\n\n**Bold answer** with `code`."}, nil)
			time.Sleep(150 * time.Millisecond)
			send(map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "visual-read", "type": "function", "function": map[string]any{"name": "read", "arguments": "{\"path\":\"sample.txt\"}"}}}}, nil)
			send(map[string]any{}, "tool_calls")
		}
		io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer server.Close()
	if err := os.MkdirAll(filepath.Join(home, ".cetas"), 0700); err != nil {
		t.Fatal(err)
	}
	settings := fmt.Sprintf(`{"providers":{"screen-fixture":{"base_url":%q,"model":"screen-model","api_key":"not-a-real-key","context_window":128000}}}`, server.URL+"/v1")
	if err := os.WriteFile(filepath.Join(home, ".cetas", "settings.json"), []byte(settings), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	hosts := make(chan *harness.Host, 1)
	start := func() (tui.Runtime, bool, error) {
		h, err := harness.Start(ctx)
		if err != nil {
			return nil, false, err
		}
		hosts <- h
		return h, h.NeedsSetup(), nil
	}
	frames := make(chan string, 512)
	p := tea.NewProgram(observedShell{Model: tui.New(start, "test"), frames: frames}, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(), tea.WithWindowSize(108, 36), tea.WithContext(ctx))
	done := make(chan error, 1)
	go func() {
		final, err := p.Run()
		if presentation, ok := final.(interface{ Close() }); ok {
			presentation.Close()
		}
		done <- err
	}()
	defer func() {
		p.Send(tea.QuitMsg{})
		cancel()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("shell did not quit")
		}
		select {
		case h := <-hosts:
			closeCtx, end := context.WithTimeout(context.Background(), 3*time.Second)
			defer end()
			if err := h.Close(closeCtx); err != nil {
				t.Error(err)
			}
		default:
		}
	}()
	sent := false
	thinking, markdown, tool, userSurface, warning := false, false, false, false, false
	var last string
	for {
		select {
		case frame := <-frames:
			last = ansi.Strip(frame)
			if !sent && strings.Contains(last, "screen-fixture/screen-model") && strings.Contains(last, "yolo") {
				sent = true
				p.Send(tea.ForegroundColorMsg{Color: color.RGBA{240, 240, 240, 255}})
				p.Send(tea.BackgroundColorMsg{Color: color.RGBA{12, 12, 12, 255}})
				p.Send(tea.KeyPressMsg{Code: 'v', Text: "visual prompt"})
				p.Send(tea.KeyPressMsg{Code: tea.KeyEnter})
			}
			warning = warning || strings.Contains(last, "Configuration warning: runtime")
			thinking = thinking || strings.Contains(last, "thinking...") && strings.Contains(last, "Inspect evidence.")
			markdown = markdown || strings.Contains(last, "Bold answer") && !strings.Contains(last, "**Bold answer**")
			// JS readSpec has no title override: the wire name is lowercase.
			tool = tool || strings.Contains(last, "● read sample.txt")
			if strings.Contains(last, "bad EventHub frame") {
				t.Fatalf("valid tool args were rejected by the harness: %s", last)
			}
			userSurface = userSurface || strings.Contains(frame, "\x1b[48;2;") && strings.Contains(last, "> visual prompt")
			if strings.Contains(last, "Final fixture answer.") {
				if !thinking || !markdown || !tool || !userSurface || !warning {
					t.Fatalf("screen projection incomplete: thinking=%v markdown=%v tool=%v user surface=%v warning=%v\n%s", thinking, markdown, tool, userSurface, warning, last)
				}
				return
			}
		case <-ctx.Done():
			t.Fatalf("real UI flow stalled (submitted=%v):\n%s", sent, last)
		case err := <-done:
			t.Fatalf("shell exited before result: %v\n%s", err, last)
		}
	}
}
