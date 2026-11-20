package harness

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/colmugx/cetas/cetas-go/internal/localipc"
	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

func TestPiCustomEntryRPCIsHostPrivate(t *testing.T) {
	host := &Host{}
	for _, command := range []string{"pi_guest_entries", "pi_guest_append_entries"} {
		if _, err := host.Request(context.Background(), command, map[string]any{
			"session_id": "arbitrary",
		}); err == nil || !strings.Contains(err.Error(), "host-private") {
			t.Fatalf("%s exposed private Pi journal RPC to public Host.Request: %v", command, err)
		}
	}
}

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
	// A live provider turn is held in the mock until both independent local
	// observers have acknowledged the authoritative working Snapshot.
	// It is released only once both Go and Bun have attached.
	releaseLiveTurn := make(chan struct{})
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
		hasResult, hasDelegationResult := false, false
		for _, message := range request.Messages {
			if message.Role == "tool" && message.CallID == "native-ui-read" {
				hasResult = true
			}
			if message.Role == "tool" && message.CallID == "native-ui-agent" {
				hasDelegationResult = true
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

		liveBridgeFixture := strings.Contains(string(body), "native-owner-live-bridge-fixture")
		if liveBridgeFixture {
			chunks = []string{
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"owner starting "},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"live from Go owner to Bun"},"finish_reason":null}]}`,
				`{"id":"mock","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
				`[DONE]`,
			}
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for i, chunk := range chunks {
			if liveBridgeFixture && i == 1 {
				select {
				case <-releaseLiveTurn:
				case <-r.Context().Done():
					return
				case <-time.After(25 * time.Second):
					return
				}
			}
			_, _ = io.WriteString(w, "data: "+chunk+"\n\n")
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
		}
	}))
	defer llm.Close()
	config := []byte(fmt.Sprintf(`{"providers":{"cetas-go-ci":{"base_url":%q,"model":"cetas-go-infra-test","api_key":"not-a-real-key"}}}`, llm.URL+"/v1"))
	if err := os.WriteFile(filepath.Join(home, ".cetas", "settings.json"), config, 0600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("CETAS_HOME", home)
	// Exercise the explicit owner-lease path in the real native integration
	// test even though ordinary Cetas startup defaults to IPC-independent.
	t.Setenv("CETAS_IPC_OWNER", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	h, err := Start(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// A failure, Fatal or platform-specific Skip below must not leave the
	// owner.lock handle open through TempDir's cleanup (Windows refuses to
	// remove locked files). The cleanup has its own deadline because the
	// test's request context may already be expired when an assertion fails.
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		if err := h.Close(cleanupCtx); err != nil {
			t.Errorf("native harness cleanup: %v", err)
		}
	})
	// The opted-in owner serves its already-composed Session without
	// creating a second Agent, using the same bridge as the Bun client.
	runtimeFrame, err := h.Request(ctx, "runtime_state", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	var state struct{ SessionID string `json:"session_id"` }
	if err := json.Unmarshal(runtimeFrame, &state); err != nil || state.SessionID == "" {
		t.Fatalf("runtime returned no owned Session: %s %v", runtimeFrame, err)
	}
	conn, err := localipc.DialLocal(ctx, home)
	if err != nil { t.Fatalf("local Session bridge: %v", err) }
	viewer, err := sb.ObserveConn(ctx, conn, state.SessionID, "native-bridge-test")
	if err != nil { t.Fatalf("attach existing Session: %v", err) }
	var observed struct {
		Type string `json:"type"`
		SessionID string `json:"session_id"`
		Busy bool `json:"busy"`
	}
	if err := json.Unmarshal(viewer.Snapshot, &observed); err != nil ||
		observed.Type != "session.snapshot" || observed.SessionID != state.SessionID {
		t.Fatalf("invalid owned Session snapshot: %s %v", viewer.Snapshot, err)
	}
	_ = viewer.Close()
	// Real second OS process (not a goroutine or a second in-process Agent)
	// joins the existing Owner over the same local IPC endpoint. The child
	// starts NO MoonBit scheduler and must never acquire a journal writer.
	childCtx, stopChild := context.WithTimeout(ctx, 15*time.Second)
	defer stopChild()
	child := exec.CommandContext(childCtx, os.Args[0], "-test.run=^TestForeignProcessSessionObserver$")
	child.Env = append(os.Environ(),
		"CETAS_GO_OBSERVER_CHILD=1",
		"CETAS_TEST_SESSION_ID="+state.SessionID,
	)
	output, childErr := child.CombinedOutput()
	if childErr != nil {
		t.Fatalf("independent Cetas process could not observe owned Session: %v (%s)", childErr, output)
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

	// Native without Bun must not compose or install any Pi adaptor.
	if h.PiAvailable() {
		t.Fatal("unexpected Pi guest without Bun")
	}
	catalog, err := h.Request(ctx, "extensions", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(catalog), "cetas_native_pi_guest") {
		t.Fatal("Pi adaptor was composed without Bun")
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

	checkSwitchSupersedesQueuedReplay(t, h, home)
	checkSessionCatalogAnchorRoundTrip(t, h, home)
	checkReplayDoesNotMonopolizeDispatcher(t, h, home)
	checkLiveCrossProcessSessionBridge(t, ctx, h, state.SessionID, releaseLiveTurn, seen)
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

// TestForeignProcessSessionObserver only runs when invoked as an independent
// child of TestNativeHarnessHost. It deliberately never calls harness.Start:
// observing an existing writer must not compose a second native Agent.
func TestForeignProcessSessionObserver(t *testing.T) {
	if os.Getenv("CETAS_GO_OBSERVER_CHILD") != "1" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sessionID := os.Getenv("CETAS_TEST_SESSION_ID")
	if sessionID == "" {
		t.Fatal("missing parent-owned Session ID")
	}
	var viewerHost Host
	viewer, err := viewerHost.ObserveSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("foreign child could not attach to local owner: %v", err)
	}
	defer viewer.Close()
	var snapshot struct {
		Type string `json:"type"`
		SessionID string `json:"session_id"`
		RuntimeEpoch string `json:"runtime_epoch"`
		Busy bool `json:"busy"`
	}
	if err := json.Unmarshal(viewer.Snapshot, &snapshot); err != nil ||
		snapshot.Type != "session.snapshot" || snapshot.SessionID != sessionID ||
		snapshot.RuntimeEpoch == "" || snapshot.RuntimeEpoch != viewer.Epoch {
		t.Fatalf("foreign child got incompatible Owner snapshot: %s %v", viewer.Snapshot, err)
	}
}


// checkLiveCrossProcessSessionBridge verifies the user-facing working/live
// semantics against the real native Agent and two *independent* observer
// processes. The mock model pauses mid-turn until both viewers have joined.
// A protocol-only handshake, in-memory test server, or completed-before-join
// turn is insufficient evidence for these cases.
func checkLiveCrossProcessSessionBridge(
	t *testing.T, parent context.Context, h *Host, sessionID string,
	release chan struct{}, seen <-chan Event,
) {
	t.Helper()
	ctx, cancel := context.WithTimeout(parent, 35*time.Second)
	defer cancel()
	var releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })

	turn, err := h.Request(ctx, "turn_start", map[string]any{
		"prompt": "native-owner-live-bridge-fixture",
	})
	if err != nil {
		t.Fatalf("start live Owner turn: %v (%s)", err, turn)
	}
	// The Owner has actually accepted the turn before a viewer joins.
	for started := false; !started; {
		select {
		case event := <-seen:
			if event.Type == "turn.started" || event.Type == "turn.accepted" {
				started = true
			} else if event.Type == "turn.failed" {
				t.Fatalf("Owner failed before attach: %s", event.Raw)
			}
		case <-ctx.Done():
			t.Fatalf("Owner never started the live test turn: %v", ctx.Err())
		}
	}

	type viewerProcess struct {
		cmd *exec.Cmd
		lines <-chan string
		stderr *bytes.Buffer
	}
	startViewer := func(label, name string, args ...string) viewerProcess {
		t.Helper()
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Env = append(os.Environ(),
			"CETAS_GO_LIVE_OBSERVER_CHILD=1",
			"CETAS_TEST_SESSION_ID="+sessionID,
		)
		stdout, err := cmd.StdoutPipe()
		if err != nil { t.Fatalf("%s stdout: %v", label, err) }
		stderr := &bytes.Buffer{}
		cmd.Stderr = stderr
		if err := cmd.Start(); err != nil { t.Fatalf("%s start: %v", label, err) }
		lines := make(chan string, 32)
		go func() {
			defer close(lines)
			scanner := bufio.NewScanner(stdout)
			scanner.Buffer(make([]byte, 4096), 1<<20)
			for scanner.Scan() {
				lines <- scanner.Text()
			}
		}()
		return viewerProcess{cmd:cmd, lines:lines, stderr:stderr}
	}
	waitMarker := func(label string, proc viewerProcess, marker string) {
		t.Helper()
		for {
			select {
			case line, ok := <-proc.lines:
				if !ok { t.Fatalf("%s exited before %s: %s", label, marker, proc.stderr.String()) }
				if strings.Contains(line, marker) { return }
			case <-ctx.Done():
				t.Fatalf("%s timed out waiting for %s: %s (%v)", label, marker, proc.stderr.String(), ctx.Err())
			}
		}
	}
	goViewer := startViewer("Go", os.Args[0], "-test.run=^TestForeignProcessLiveSessionObserver$")
	defer func() { _ = goViewer.cmd.Process.Kill(); _ = goViewer.cmd.Wait() }()
	waitMarker("Go", goViewer, "FOREIGN_SNAPSHOT_WORKING")

	var bunViewer *viewerProcess
	if bun, err := exec.LookPath("bun"); err == nil {
		// Native CI installs Bun before running Go tests on all three OSes.
		// The adapter is the real cetas-js observer and no Agent is composed.
		b := startViewer("Bun", bun, "run", filepath.Join("..", "..", "cetas-js", "tests", "session-bridge-bun-viewer.ts"))
		bunViewer = &b
		defer func() { _ = b.cmd.Process.Kill(); _ = b.cmd.Wait() }()
		waitMarker("Bun", b, "FOREIGN_SNAPSHOT_WORKING")
	} else {
		t.Logf("Bun not installed; native Go-to-Go live check runs, Bun cross-host part skipped: %v", err)
	}
	// Both processes joined an already-working Owner. Only now allow its
	// provider to emit the assistant delta; receivers must see it live.
	releaseOnce.Do(func() { close(release) })
	waitMarker("Go", goViewer, "FOREIGN_STREAM_OK")
	if bunViewer != nil {
		waitMarker("Bun", *bunViewer, "FOREIGN_STREAM_OK")
	}
	// Confirm the same owner turn settles, without requiring either viewer
	// to issue a command, own the journal or compose another Agent.
	for {
		select {
		case event := <-seen:
			if event.Type == "turn.completed" { return }
			if event.Type == "turn.failed" { t.Fatalf("Owner turn failed: %s", event.Raw) }
		case <-ctx.Done():
			t.Fatalf("Owner did not complete after the viewers received live output: %v", ctx.Err())
		}
	}
}

// Runs only inside the spawned Go observer process. Never compose a second
// native Harness or issue write commands against the Owner's Session.
func TestForeignProcessLiveSessionObserver(t *testing.T) {
	if os.Getenv("CETAS_GO_LIVE_OBSERVER_CHILD") != "1" { return }
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	sessionID := os.Getenv("CETAS_TEST_SESSION_ID")
	if sessionID == "" { t.Fatal("missing live Owner Session ID") }
	var observerHost Host
	viewer, err := observerHost.ObserveSession(ctx, sessionID)
	if err != nil { t.Fatalf("Go viewer could not observe live Owner: %v", err) }
	defer viewer.Close()
	var snapshot struct {
		Type string `json:"type"`
		SessionID string `json:"session_id"`
		RuntimeEpoch string `json:"runtime_epoch"`
		Busy bool `json:"busy"`
	}
	if err := json.Unmarshal(viewer.Snapshot, &snapshot); err != nil ||
		snapshot.Type != "session.snapshot" || snapshot.SessionID != sessionID ||
		snapshot.RuntimeEpoch != viewer.Epoch || !snapshot.Busy {
		t.Fatalf("Go viewer did not receive authoritative working Snapshot: %s (%v)", viewer.Snapshot, err)
	}
	fmt.Println("FOREIGN_SNAPSHOT_WORKING")
	var textOutput strings.Builder
	for !strings.Contains(textOutput.String(), "live from Go owner to Bun") {
		frame, err := viewer.Next()
		if err != nil { t.Fatalf("Go Owner live stream stopped: %v", err) }
		var event struct {
			Type string `json:"type"`
			Delta string `json:"delta"`
		}
		if err := json.Unmarshal(frame, &event); err != nil { t.Fatal(err) }
		if event.Type == "assistant.text_delta" { textOutput.WriteString(event.Delta) }
	}
	fmt.Println("FOREIGN_STREAM_OK")
}
