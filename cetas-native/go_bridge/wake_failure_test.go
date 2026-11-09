package bridge

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The notification channels are process-global and cannot be broken inside a
// healthy process, so their failure paths are exercised by re-executing this
// test binary with a fault injected at channel creation. Nothing is swallowed:
// the Go pump must name the stage and the MoonBit loop must report one explicit
// degraded diagnostic and stop retrying the dead descriptor.
const (
	forceEventWakeEnv   = "CETAS_NATIVE_TEST_FORCE_EVENT_WAKE_FAILURE"
	forceCommandWakeEnv = "CETAS_NATIVE_TEST_FORCE_COMMAND_WAKE_FAILURE"
)

// runFaultChild runs one child test with a fault injected and fails unless the
// child passed, so the injected path's assertions are the real evidence.
func runFaultChild(t *testing.T, env, child string) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^"+child+"$", "-test.v", "-test.count=1")
	cmd.Env = append(os.Environ(), env+"=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("fault-injected child %s failed: %v\n%s", child, err, out)
	}
	if !strings.Contains(string(out), "--- PASS: "+child) {
		t.Fatalf("fault-injected child %s did not pass:\n%s", child, out)
	}
}

// A pump whose event channel is gone must fail with the exact reason instead of
// blocking forever or pretending to wait, while the queue keeps working.
func TestEventChannelFailureChild(t *testing.T) {
	if os.Getenv(forceEventWakeEnv) == "" {
		t.Skip("fault-injection child only")
	}
	h := transportUnderTest()
	if err := h.Wait(); err == nil {
		t.Fatal("Wait must report an unusable notification channel instead of blocking")
	} else if !strings.Contains(err.Error(), "notification channel unusable") ||
		!strings.Contains(err.Error(), "disabled by a transport test") {
		t.Fatalf("Wait lost its cause: %v", err)
	}
	if err := h.Wake(); err == nil || !strings.Contains(err.Error(), "unusable") {
		t.Fatalf("Wake must report the same cause, got %v", err)
	}
	// Without notifications the bounded queue is still authoritative.
	if publishFrame([]byte(`{"type":"infra.ping"}`)) != 1 {
		t.Fatal("publish failed")
	}
	frames := drainAll(t, h)
	if len(frames) != 1 || !strings.Contains(string(frames[0]), "infra.ping") {
		t.Fatalf("queue delivery without notifications: %d frame(s)", len(frames))
	}
}

// The scheduler side degrades instead of dying: losing its notify channel keeps
// commands working through bounded polling, but it reports the reason exactly
// once and never retries the closed descriptor every iteration.
func TestDegradedCommandChannelChild(t *testing.T) {
	if os.Getenv(forceCommandWakeEnv) == "" {
		t.Skip("fault-injection child only")
	}
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
	finished := make(chan int, 1)
	go func() { finished <- h.Run() }()
	// next polls the queue the way the Go pump would; without notifications a
	// short bounded sleep replaces the wait.
	next := func() map[string]any {
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			frame, err := h.Poll()
			if err != nil {
				t.Fatalf("poll: %v", err)
			}
			if len(frame) == 0 {
				time.Sleep(2 * time.Millisecond)
				continue
			}
			var event map[string]any
			if err := json.Unmarshal(frame, &event); err != nil {
				t.Fatalf("invalid event %q: %v", frame, err)
			}
			return event
		}
		t.Fatal("timed out waiting for a frame")
		return nil
	}
	degraded := 0
	degradedDetail := ""
	state := 0
	response := 0
	deadline := time.Now().Add(30 * time.Second)
	for state == 0 || response == 0 || degraded == 0 || len(degradedDetail) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("degraded run did not settle: degraded=%d state=%d response=%d", degraded, state, response)
		}
		switch event := next(); event["type"] {
		case "infra.error":
			degraded++
			detail, _ := event["detail"].(string)
			degradedDetail = detail
			if event["degraded"] != "command_poll_10ms" {
				t.Fatalf("degraded frame must name the mode: %#v", event)
			}
		case "infra.state":
			state++
		case "harness.response":
			response++
		}
		if state == 0 && degraded > 0 {
			// Polling fallback must still serve commands.
			if err := h.Send(CommandState); err != nil {
				t.Fatalf("state send while degraded: %v", err)
			}
		}
		if response == 0 && degraded > 0 && state > 0 {
			if err := h.Submit([]byte(`{"id":7,"command":"health","args":{}}`)); err != nil {
				t.Fatalf("submit while degraded: %v", err)
			}
		}
	}
	if !strings.Contains(degradedDetail, "disabled by a transport test") ||
		!strings.Contains(degradedDetail, "10 ms command polling") {
		t.Fatalf("degraded diagnostic lost its cause or fallback: %q", degradedDetail)
	}
	if err := h.Send(CommandStop); err != nil {
		t.Fatal(err)
	}
	stopped := false
	for !stopped {
		if event := next(); event["type"] == "infra.stopped" {
			stopped = true
		}
	}
	select {
	case code := <-finished:
		if code != 1 {
			t.Fatalf("degraded scheduler exited with %d", code)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("degraded scheduler did not exit")
	}
	// Extra drain: a healthy run publishes nothing else after stop, so any
	// further infra.error would be a repeated report of the same failure.
	for {
		frame, err := h.Poll()
		if err != nil {
			t.Fatalf("final poll: %v", err)
		}
		if len(frame) == 0 {
			break
		}
		var event map[string]any
		if json.Unmarshal(frame, &event) == nil && event["type"] == "infra.error" {
			degraded++
		}
	}
	if degraded != 1 {
		t.Fatalf("degradation reported %d times, want exactly one: %s", degraded, degradedDetail)
	}
	if drops := h.DroppedEvents(); drops != 0 {
		t.Fatalf("degraded run lost %d frames", drops)
	}
	fmt.Fprintf(os.Stderr, "degraded diagnostic: %s\n", degradedDetail)
}

// Parent wrappers: they only re-execute the children with the fault injected.
func TestEventChannelFailureIsReported(t *testing.T) {
	if os.Getenv(forceEventWakeEnv) != "" {
		t.Skip("running as the fault-injection child")
	}
	runFaultChild(t, forceEventWakeEnv, "TestEventChannelFailureChild")
}

func TestCommandChannelDegradationIsReportedOnce(t *testing.T) {
	if os.Getenv(forceCommandWakeEnv) != "" {
		t.Skip("running as the fault-injection child")
	}
	runFaultChild(t, forceCommandWakeEnv, "TestDegradedCommandChannelChild")
}
