package bridge

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestInfraLifecycle insists on a REAL ConsoleRuntime ready state.
// Provider metadata is static and local, and the endpoint is deliberately
// unreachable: the infrastructure boot must not require a model request.
func TestInfraLifecycle(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".cetas"), 0700); err != nil {
		t.Fatal(err)
	}
	fixture := []byte(`{"providers":{"cetas-native-ci":{"base_url":"http://127.0.0.1:1/v1","model":"cetas-native-infra-test","api_key":"ci-not-a-secret"}}}`)
	if err := os.WriteFile(filepath.Join(home, ".cetas", "settings.json"), fixture, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CETAS_HOME", home)

	h := NewInfra()
	dropsBefore := h.DroppedEvents()
	finished := make(chan int, 1)
	go func() { finished <- h.Run() }()
	wait := func(want string) map[string]any {
		deadline := time.Now().Add(35 * time.Second)
		for time.Now().Before(deadline) {
			frame, err := h.Poll()
			if err != nil {
				t.Fatal(err)
			}
			if len(frame) == 0 {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			var event map[string]any
			if err := json.Unmarshal(frame, &event); err != nil {
				t.Fatalf("invalid event %q: %v", frame, err)
			}
			t.Logf("infra frame: %s", frame)
			if event["type"] == want {
				return event
			}
		}
		t.Fatalf("timed out waiting for %s", want)
		return nil
	}
	boot := wait("infra.boot")
	if boot["status"] != "ready" {
		t.Fatalf("real ConsoleRuntime failed to compose: %#v", boot)
	}
	snapshot, ok := boot["snapshot"].(map[string]any)
	if !ok || snapshot["status"] != "ready" {
		t.Fatalf("invalid runtime snapshot: %#v", boot)
	}
	if err := h.Send(CommandState); err != nil {
		t.Fatal(err)
	}
	state := wait("infra.state")
	if state["snapshot"] == nil {
		t.Fatalf("state response lacks runtime data: %#v", state)
	}
	if err := h.Send(CommandPing); err != nil {
		t.Fatal(err)
	}
	ping := wait("infra.ping")
	if ping["source"] != "moonbit" || ping["event_id"] == nil || ping["seq"] == nil {
		t.Fatalf("EventHub frame lacks event metadata: %#v", ping)
	}
	workspaces := wait("infra.workspaces")
	if workspaces["snapshot"] == nil {
		t.Fatalf("missing workspace result: %#v", workspaces)
	}
	// Multiple goroutines may enqueue concurrently, but MoonBit reads
	// every command on its single dispatcher OS thread.
	const burst = 48
	failures := make(chan error, burst)
	for i := 0; i < burst; i++ {
		go func() { failures <- h.Send(CommandState) }()
	}
	for i := 0; i < burst; i++ {
		if err := <-failures; err != nil {
			t.Fatalf("burst enqueue: %v", err)
		}
	}
	for i := 0; i < burst; i++ {
		next := wait("infra.state")
		if next["snapshot"] == nil {
			t.Fatalf("burst response has no state: %#v", next)
		}
	}
	// Cross the *real* Go -> C -> MoonBit -> C -> Go command boundary.
	harnessCases := []struct {
		id      int
		command string
		args    string
		wantKey string
	}{
		{101, "health", "{}", "status"},
		{102, "versions", "{}", "cetas"},
		{103, "runtime_state", "{}", "status"},
		{104, "sessions", "{}", "sessions"},
		{105, "models", "{}", "slots"},
		{106, "workspaces", "{}", "active"},
		{107, "extensions", "{}", "extensions"},
		{108, "attach", "{}", "session_id"},
		{109, "set_permission", `{"mode":"readonly"}`, "permission"},
		{110, "turn_start", `{"prompt":"   "}`, "error"},
		{111, "session_transcript", "{}", "error"},
		{112, "invalid_command", "{}", "error"},
	}
	for _, tc := range harnessCases {
		payload := []byte(fmt.Sprintf(`{"id":%d,"command":%q,"args":%s}`, tc.id, tc.command, tc.args))
		if err := h.Submit(payload); err != nil {
			t.Fatalf("%s submit: %v", tc.command, err)
		}
		resp := wait("harness.response")
		if int(resp["id"].(float64)) != tc.id {
			t.Fatalf("response id mismatch: %#v", resp)
		}
		result, ok := resp["result"].(map[string]any)
		if !ok {
			t.Fatalf("missing result for %s: %#v", tc.command, resp)
		}
		if _, ok := result[tc.wantKey]; !ok {
			t.Fatalf("%s missing %s: %#v", tc.command, tc.wantKey, result)
		}
	}

	// Exercise a real background agent turn against an intentionally offline
	// provider. The agent must accept the turn and report failure over the
	// same EventHub stream, not synthesize it in the Go adapter.
	if err := h.Submit([]byte(`{"id":201,"command":"turn_start","args":{"prompt":"Say hello"}}`)); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(20 * time.Second)
	gotAccepted, gotResponse, gotTerminal := false, false, false
	for time.Now().Before(deadline) && !(gotAccepted && gotResponse && gotTerminal) {
		frame, err := h.Poll()
		if err != nil {
			t.Fatal(err)
		}
		if len(frame) == 0 {
			time.Sleep(5 * time.Millisecond)
			continue
		}
		var event map[string]any
		if err := json.Unmarshal(frame, &event); err != nil {
			t.Fatal(err)
		}
		switch event["type"] {
		case "turn.accepted":
			gotAccepted = true
		case "harness.response":
			if event["id"] == float64(201) {
				res, ok := event["result"].(map[string]any)
				if !ok || res["turn_id"] == nil {
					t.Fatalf("turn_start response: %#v", event)
				}
				gotResponse = true
			}
		case "turn.failed", "turn.completed":
			gotTerminal = true
		}
	}
	if !gotAccepted || !gotResponse || !gotTerminal {
		t.Fatalf("real turn lifecycle accepted=%v response=%v terminal=%v", gotAccepted, gotResponse, gotTerminal)
	}
	if err := h.Submit([]byte(`{"id":202,"command":"turn_abort","args":{}}`)); err != nil {
		t.Fatal(err)
	}
	aborted := wait("harness.response")
	if aborted["id"] != float64(202) {
		t.Fatalf("abort response id: %#v", aborted)
	}
	if err := h.Submit([]byte(`{"id":203,"command":"ui_response","args":{"request_id":"unknown","cancelled":true}}`)); err != nil {
		t.Fatal(err)
	}
	uiResponse := wait("harness.response")
	if uiResponse["id"] != float64(203) {
		t.Fatalf("ui response id: %#v", uiResponse)
	}
	if err := h.Send(CommandStop); err != nil {
		t.Fatal(err)
	}
	wait("infra.stopped")
	select {
	case ret := <-finished:
		if ret != 1 {
			t.Fatalf("MoonBit async returned %d", ret)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("MoonBit dispatcher did not exit")
	}
	if drops := h.DroppedEvents() - dropsBefore; drops != 0 {
		t.Fatalf("lost %d events", drops)
	}
}
