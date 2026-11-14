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
	"sync/atomic"
	"testing"
	"time"
)

func TestNativeHarnessHost(t *testing.T) {
	home := t.TempDir()
	workspace := t.TempDir()
	t.Chdir(workspace)
	if err := os.WriteFile("parity.txt", []byte("native-ui fixture\n"), 0600); err != nil {
		t.Fatal(err)
	}
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
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		var request struct {
			Messages []struct {
				Role   string `json:"role"`
				CallID string `json:"tool_call_id"`
			} `json:"messages"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		hasResult, hasDelegationResult, hasPiResult := false, false, false
		for _, message := range request.Messages {
			if message.Role == "tool" && message.CallID == "native-ui-read" {
				hasResult = true
			}
			if message.Role == "tool" && message.CallID == "native-ui-agent" {
				hasDelegationResult = true
			}
			if message.Role == "tool" && message.CallID == "native-pi-echo" {
				hasPiResult = true
			}
		}
		chunks := []string{
			`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"Check the evidence first.\nThen answer clearly."},"finish_reason":null}]}`,
			`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello from Cetas"},"finish_reason":null}]}`,
			`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
			`[DONE]`,
		}
		if strings.Contains(string(body), "native-ui-tool-fixture") && !hasResult {
			chunks = []string{
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"native-ui-read","type":"function","function":{"name":"read","arguments":"{\"path\":"}}]},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"parity.txt\"}"}}]},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
				`[DONE]`,
			}
		}
		if strings.Contains(string(body), "native-ui-delegation-fixture") && !hasDelegationResult {
			chunks = []string{
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"native-ui-agent","type":"function","function":{"name":"subagent","arguments":"{\"kind\":\"explore\",\"task\":\"Say child hello\",\"background\":false,\"tools\":[\"read\"]}"}},{"index":1,"id":"native-ui-notify","type":"function","function":{"name":"notify_user","arguments":"{\"question\":\"Continue?\",\"type\":\"confirm\"}"}}]},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
				`[DONE]`,
			}
		}
		if strings.Contains(string(body), "native-ui-pi-fixture") && !hasPiResult {
			chunks = []string{
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"native-pi-echo","type":"function","function":{"name":"pi_native_echo","arguments":"{\"text\":\"native\"}"}}]},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
				`[DONE]`,
			}
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, chunk := range chunks {
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

	// Allowlisted unmodified Pi module. It must be loaded by the *in-process*
	// moejs VM and executed through the same MoonBit/Posoco Agent as base tools.
	piDir := filepath.Join(home, ".cetas", "pi-packages", "pi-native-fixture")
	if err := os.MkdirAll(piDir, 0700); err != nil { t.Fatal(err) }
	for path, source := range map[string]string{
		filepath.Join(home, ".cetas", "pi-packages.json"): `{"packages":["pi-native-fixture"]}`,
		filepath.Join(piDir, "package.json"): `{"name":"pi-native-fixture","pi":{"extensions":["./index.mjs"]}}`,
		filepath.Join(piDir, "index.mjs"): `export default function(pi) {
			pi.registerTool({
				name:"pi_native_echo",
				description:"Echo without leaving the Posoco Agent",
				parameters:{type:"object",properties:{text:{type:"string",minLength:1}},required:["text"]},
				async execute(callId, params) {
					const text = await Promise.resolve(params.text);
					return {content:[{type:"text",text:"echo:"+text}]};
				}
			});
		}`,
	} {
		if err := os.WriteFile(path, []byte(source), 0600); err != nil { t.Fatal(err) }
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
	var snapshotDelivered atomic.Bool
	wg.Add(1)
	go func() {
		defer wg.Done()
		for event := range h.Events() {
			if event.Type == "session.snapshot" {
				snapshotDelivered.Store(true)
			}
			select {
			case seen <- event:
			default:
			}
		}
	}()

	// The VM is initialized after the first Agent Session is composed. The
	// readiness event is emitted only after the Kernel accepts the catalog.
	select {
	case <-time.After(15 * time.Second):
		t.Fatal("allowlisted native Pi tools were never installed into Posoco")
	case event := <-seen:
		if event.Type != "pi.guest.installed" {
			// Ordinary bootstrap events may precede the guest publication.
			deadline := time.After(15 * time.Second)
			for event.Type != "pi.guest.installed" {
				select {
				case event = <-seen:
				case <-deadline:
					t.Fatal("no Pi tool publication after Native guest startup")
				}
			}
		}
	}
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
	successful, reasoningSeen := false, false
	until := time.After(15 * time.Second)
waitTurn:
	for {
		select {
		case evt := <-seen:
			if evt.Type == "assistant.reasoning_delta" {
				reasoningSeen = true
			}
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
	if !reasoningSeen {
		t.Fatal("real provider reasoning never crossed the native bridge")
	}
	// The new projection must cross the real MoonBit/C/Go path, not merely
	// render artificial Go fixtures. Reuse this process-singleton runtime.
	if _, err := h.Request(ctx, "status_refresh", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Request(ctx, "turn_start", map[string]any{"prompt": "native-ui-tool-fixture"}); err != nil {
		t.Fatal(err)
	}
	phases := []string{}
	argsSeen, renderSeen := false, false
	deadline := time.After(15 * time.Second)
projectedTurn:
	for {
		select {
		case evt := <-seen:
			var frame struct {
				Type, Phase string
				ID          string `json:"tool_call_id"`
				Render      struct {
					Body json.RawMessage `json:"body"`
				} `json:"render"`
			}
			if err := json.Unmarshal(evt.Raw, &frame); err != nil {
				t.Fatal(err)
			}
			if evt.Type == "tool.args_delta" {
				argsSeen = true
			}
			if frame.ID == "native-ui-read" && frame.Phase != "" {
				phases = append(phases, frame.Phase)
			}
			if evt.Type == "ui.render" && len(frame.Render.Body) > 0 {
				renderSeen = true
			}
			if evt.Type == "turn.failed" {
				t.Fatalf("projected tool turn failed: %s", evt.Raw)
			}
			if evt.Type == "turn.completed" {
				break projectedTurn
			}
		case <-deadline:
			t.Fatal("projected tool turn did not settle")
		}
	}
	if strings.Join(phases, ",") != "pending,approved,started,succeeded" || !argsSeen || !renderSeen {
		t.Fatalf("native bridge projection missing: phases=%v streamed args=%v UI body=%v", phases, argsSeen, renderSeen)
	}
	// Exercise the newly composed extensions, not just their encoders: one
	// foreground child plus a parked human question over the real bridge.
	// Earlier contract checks deliberately selected readonly. These tools are
	// correctly denied there; explicitly authorize this isolated fixture rather
	// than relying on (or weakening) any product default permission.
	if _, err := h.Request(ctx, "set_permission", map[string]any{"mode": "yolo"}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Request(ctx, "turn_start", map[string]any{"prompt": "native-ui-delegation-fixture"}); err != nil {
		t.Fatal(err)
	}
	childStarted, childEnded, questionID := false, false, ""
	delegationReceipts := []string{}
	deadline = time.After(15 * time.Second)
delegationTurn:
	for {
		select {
		case evt := <-seen:
			var frame struct {
				Child      string `json:"child_session"`
				Call       string `json:"parent_call"`
				QuestionID string `json:"question_id"`
				Kind       string `json:"kind"`
				Ev         struct {
					Type string `json:"type"`
				} `json:"ev"`
			}
			if err := json.Unmarshal(evt.Raw, &frame); err != nil {
				t.Fatal(err)
			}
			if evt.Type == "tool.completed" || evt.Type == "ui.request" {
				delegationReceipts = append(delegationReceipts, string(evt.Raw))
			}
			if evt.Type == "subagent.event" {
				if frame.Child == "" || frame.Call != "native-ui-agent" {
					t.Fatalf("lost real child attribution: %s", evt.Raw)
				}
				if frame.Ev.Type == "turn.started" {
					childStarted = true
				}
				if frame.Ev.Type == "turn.completed" {
					childEnded = true
				}
			}
			if evt.Type == "question.asked" {
				questionID = frame.QuestionID
				if frame.Kind != "confirm" {
					t.Fatalf("question kind overwrote envelope: %s", evt.Raw)
				}
			}
			if evt.Type == "turn.failed" {
				t.Fatalf("delegation turn failed: %s", evt.Raw)
			}
			if evt.Type == "turn.completed" {
				break delegationTurn
			}
		case <-deadline:
			t.Fatal("delegation turn did not settle")
		}
	}
	if !childStarted || !childEnded || questionID == "" {
		t.Fatalf("real extension sources missing: child start=%v end=%v question=%q receipts=%v", childStarted, childEnded, questionID, delegationReceipts)
	}
	if _, err := h.Request(ctx, "ui_response", map[string]any{"request_id": questionID, "yes": true}); err != nil {
		t.Fatal(err)
	}
	deadline = time.After(5 * time.Second)
answeredQuestion:
	for {
		select {
		case evt := <-seen:
			if evt.Type == "question.answered" {
				break answeredQuestion
			}
		case <-deadline:
			t.Fatal("typed question answer did not reach its extension registry")
		}
	}

	// A real provider-generated tool call must cross the Posoco runtime,
	// Go/moejs extension callback, and correlated result inbox. It is not a
	// direct JS runner test.
	if _, err := h.Request(ctx, "turn_start", map[string]any{"prompt": "native-ui-pi-fixture"}); err != nil {
		t.Fatal(err)
	}
	piExecuted, piSucceeded := false, false
	piDeadline := time.After(15 * time.Second)
piTurn:
	for {
		select {
		case evt := <-seen:
			if evt.Type == "pi.guest.execute" {
				piExecuted = true
			}
			if evt.Type == "tool.completed" || evt.Type == "tool.succeeded" {
				if strings.Contains(string(evt.Raw), "native-pi-echo") {
					piSucceeded = true
				}
			}
			if evt.Type == "turn.failed" {
				t.Fatalf("native Pi Agent turn failed: %s", evt.Raw)
			}
			if evt.Type == "turn.completed" {
				break piTurn
			}
		case <-piDeadline:
			t.Fatal("Pi extension call never returned to the Posoco Agent")
		}
	}
	if !piExecuted || !piSucceeded {
		t.Fatalf("Pi guest did not complete the Agent effect: executed=%v succeeded=%v", piExecuted, piSucceeded)
	}
	checkSwitchSupersedesQueuedReplay(t, h, home)
	checkSessionCatalogAnchorRoundTrip(t, h, home)
	checkReplayDoesNotMonopolizeDispatcher(t, h, home)
	if err := h.Close(ctx); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	// Earlier turn loops consume snapshots too; subscription delivery cannot
	// depend on an unrelated snapshot being left over after shutdown.
	gotSnapshot := snapshotDelivered.Load()
	for len(seen) > 0 {
		if (<-seen).Type == "session.snapshot" {
			gotSnapshot = true
		}
	}
	if !gotSnapshot {
		t.Fatal("EventHub did not reach Go host event subscription")
	}
}
