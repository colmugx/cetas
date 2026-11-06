package harness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNativeHarnessHost(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".cetas"), 0700); err != nil {
		t.Fatal(err)
	}
	// Real compatible-provider factory and router; no secrets or network I/O.
	// Test-only in-process mock LLM endpoint. Not a Cetas app sidecar:
	// this simulates the external model API and exists only inside go test.
	llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, chunk := range []string{
			`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello from Cetas"},"finish_reason":null}]}`,
			`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
			`[DONE]`,
		} {
			_, _ = io.WriteString(w, "data: "+chunk+"\n\n")
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
		}
	}))
	defer llm.Close()
	config := []byte(fmt.Sprintf(`{"providers":{"cetas-native-ci":{"base_url":%q,"model":"cetas-native-infra-test","api_key":"not-a-real-key"}}}`, llm.URL+"/v1"))
	if err := os.WriteFile(filepath.Join(home, ".cetas", "settings.json"), config, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CETAS_HOME", home)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	h, err := Start(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// The thread-owner runtime is process-singleton, not an accidental set
	// of parallel MoonBit interpreters created from Go goroutines.
	if _, err := Start(ctx); !errors.Is(err, ErrAlreadyStarted) {
		t.Fatalf("duplicate Start: %v", err)
	}
	var wg sync.WaitGroup
	seen := make(chan Event, 512)
	wg.Add(1)
	go func() {
		defer wg.Done()
		for event := range h.Events() {
			select {
			case seen <- event:
			default:
			}
		}
	}()
	commands := []struct {
		name string
		args any
		want string
	}{
		{"health", map[string]any{}, "ok"},
		{"runtime_state", map[string]any{}, "ready"},
		{"set_permission", map[string]any{"mode": "readonly"}, "readonly"},
		{"workspaces", map[string]any{}, "workspaces"},
		{"turn_start", map[string]any{"prompt": "   "}, "error"},
		{"ui_response", map[string]any{"request_id": "not-present", "cancelled": true}, "ok"},
	}
	for _, test := range commands {
		payload, err := h.Request(ctx, test.name, test.args)
		if test.want == "error" {
			if err == nil {
				t.Fatalf("%s unexpectedly succeeded: %s", test.name, payload)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", test.name, err)
		}
		var decoded map[string]any
		if err := json.Unmarshal(payload, &decoded); err != nil {
			t.Fatal(err)
		}
		switch test.want {
		case "workspaces":
			if decoded["workspaces"] == nil {
				t.Fatalf("missing workspace list: %s", payload)
			}
		case "ok":
			if decoded["status"] != "ok" && decoded["ok"] != true {
				t.Fatalf("not ok: %s", payload)
			}
		default:
			if decoded["status"] != test.want && decoded["permission"] != test.want {
				t.Fatalf("%s: expected %s, got %s", test.name, test.want, payload)
			}
		}
	}
	// A long unicode command exercises >16 KiB in BOTH directions without
	// special test-only entrypoints or HTTP requests. The MoonBit dispatcher
	// returns the unknown command verbatim in its error payload.
	longCommand := strings.Repeat("界", 14000)
	largeReply, largeErr := h.Request(ctx, longCommand, map[string]any{})
	if largeErr == nil {
		t.Fatal("unknown long command unexpectedly succeeded")
	}
	if len(largeReply) < 40000 || !strings.Contains(string(largeReply), "unknown harness command:") {
		t.Fatalf("large-frame result missing or truncated: bytes=%d err=%v", len(largeReply), largeErr)
	}
	// Concurrent requests must never mix their replies, even though
	// MoonBit dispatches them sequentially on its own OS thread.
	const workers = 24
	failures := make(chan error, workers)
	for i := 0; i < workers; i++ {
		go func() {
			payload, err := h.Request(ctx, "runtime_state", map[string]any{})
			if err != nil {
				failures <- err
				return
			}
			var state map[string]any
			if err := json.Unmarshal(payload, &state); err != nil {
				failures <- err
				return
			}
			if state["status"] != "ready" {
				failures <- errors.New("wrong runtime state")
				return
			}
			failures <- nil
		}()
	}
	for i := 0; i < workers; i++ {
		if err := <-failures; err != nil {
			t.Fatal(err)
		}
	}
	// The real Cetas agent uses a test-only in-process HTTP fake of an
	// OpenAI-compatible provider. Unlike the failure-path regression, this
	// must reach a successful terminal assistant event with actual text.
	turn, err := h.Request(ctx, "turn_start", map[string]any{"prompt": "Answer with hello"})
	if err != nil {
		t.Fatalf("start turn: %v (%s)", err, turn)
	}
	var started map[string]any
	if err := json.Unmarshal(turn, &started); err != nil || started["turn_id"] == nil {
		t.Fatalf("no real turn id: %s: %v", turn, err)
	}
	successful := false
	until := time.After(15 * time.Second)
waitTurn:
	for {
		select {
		case evt := <-seen:
			if evt.Type == "turn.failed" {
				t.Fatalf("mock turn failed: %s", evt.Raw)
			}
			if evt.Type == "turn.completed" {
				successful = true
				break waitTurn
			}
		case <-until:
			t.Fatal("no real successful Cetas turn completion")
		}
	}
	if !successful {
		t.Fatal("turn did not complete")
	}
	if err := h.Close(ctx); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	gotSnapshot := false
	for len(seen) > 0 {
		if (<-seen).Type == "session.snapshot" {
			gotSnapshot = true
		}
	}
	if !gotSnapshot {
		t.Fatal("EventHub did not reach Go host event subscription")
	}
}
