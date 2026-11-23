package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// Fanout must not broadcast one Session's working or deltas to a different
// Session, nor block the owner when an observer stops reading.
func TestSessionBridgeFanoutIsolatedAndBounded(t *testing.T) {
	h := &Host{streams: make(map[uint64]sessionStream)}
	a := make(chan json.RawMessage, 1)
	b := make(chan json.RawMessage, 1)
	h.streams[1] = sessionStream{sessionID: "session-a", frames: a}
	h.streams[2] = sessionStream{sessionID: "session-b", frames: b}
	h.publishSessionFrame("session-a", []byte(`{"type":"turn.accepted","session_id":"session-a","runtime_epoch":"epoch","cursor":1,"cursor_advance":true}`))
	select {
	case raw := <-a:
		var event struct{ Type string `json:"type"` }
		if err := json.Unmarshal(raw, &event); err != nil || event.Type != "turn.accepted" {
			t.Fatalf("corrupted working event: %s %v", raw, err)
		}
	default:
		t.Fatal("owner did not publish working immediately")
	}
	select {
	case <-b:
		t.Fatal("another Session received foreign working")
	default:
	}
	// Fill the a observer and publish once more: it is retired, never
	// allowed to stall the native EventHub or continue with a cursor gap.
	h.publishSessionFrame("session-a", []byte(`{"type":"assistant.text_delta","session_id":"session-a"}`))
	h.publishSessionFrame("session-a", []byte(`{"type":"assistant.text_delta","session_id":"session-a"}`))
	h.streamsMu.Lock()
	_, exists := h.streams[1]
	_, bExists := h.streams[2]
	h.streamsMu.Unlock()
	if exists || !bExists {
		t.Fatalf("failed to isolate slow viewer: a=%v b=%v", exists, bExists)
	}
	h.closeSessionStreams()
	h.closeSessionStreams()
}

// The helper runs in a second OS process of the same go test executable.
// It connects over a real Unix socket rather than using net.Pipe, and never
// creates a second Agent, Session writer or Journal.
func TestGoProcessSessionBridgeViewer(t *testing.T) {
	if os.Getenv("CETAS_TEST_GO_BRIDGE_VIEWER") != "1" {
		return
	}
	endpoint := os.Getenv("CETAS_TEST_GO_BRIDGE_SOCKET")
	wantBusy := os.Getenv("CETAS_TEST_GO_BRIDGE_BUSY") == "true"
	ctx, cancel := context.WithTimeout(context.Background(), 9*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", endpoint)
	if err != nil {
		t.Fatal(err)
	}
	observer, err := sb.ObserveConn(ctx, conn, "shared-session", "second-go-process")
	if err != nil {
		t.Fatal(err)
	}
	defer observer.Close()
	var snapshot struct {
		Busy bool `json:"busy"`
		SessionID string `json:"session_id"`
		RuntimeEpoch string `json:"runtime_epoch"`
	}
	if err := json.Unmarshal(observer.Snapshot, &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Busy != wantBusy || snapshot.SessionID != "shared-session" ||
		snapshot.RuntimeEpoch != observer.Epoch {
		t.Fatalf("incorrect authoritative snapshot: %s", observer.Snapshot)
	}
	fmt.Println("VIEWER_READY")
	// When attached idle, the owner's next accepted turn must become working
	// before any text is streamed.
	if !wantBusy {
		raw, err := observer.Next()
		if err != nil {
			t.Fatal(err)
		}
		var event struct { Type string `json:"type"` }
		if json.Unmarshal(raw, &event) != nil || event.Type != "turn.accepted" {
			t.Fatalf("idle viewer missed immediate owner working: %s", raw)
		}
	}
	raw, err := observer.Next()
	if err != nil {
		t.Fatal(err)
	}
	var delta struct {
		Type string `json:"type"`
		Delta string `json:"delta"`
		RuntimeEpoch string `json:"runtime_epoch"`
	}
	if json.Unmarshal(raw, &delta) != nil || delta.Type != "assistant.text_delta" ||
		delta.Delta != "Go owner live output" || delta.RuntimeEpoch != observer.Epoch {
		t.Fatalf("independent Go viewer did not receive live output: %s", raw)
	}
	fmt.Println("VIEWER_RECEIVED")
}

// Two independent Go processes, a real local Unix transport and the same
// bounded Host.publishSessionFrame path used by the native EventHub pump.
// The first subcase attaches while already working; the second attaches idle
// before the owner submits, as in the requested two-terminal scenario.
func TestGoOwnerToIndependentGoViewer(t *testing.T) {
	if os.Getenv("CETAS_TEST_GO_BRIDGE_VIEWER") == "1" {
		return
	}
	if os.PathSeparator != '/' {
		t.Skip("Unix-socket process acceptance; Windows named-pipe tests are separate")
	}
	for _, alreadyWorking := range []bool{true, false} {
		name := "already-working"
		if !alreadyWorking { name = "idle-then-working" }
		t.Run(name, func(t *testing.T) {
			// macOS limits Unix socket paths to about 104 bytes; Go's
			// t.TempDir includes the full test/subtest name and exceeds it.
			// A private, short OS temp path keeps real socket transport tested.
			ownerDir, err := os.MkdirTemp("", "cetas-sb-")
			if err != nil { t.Fatal(err) }
			defer os.RemoveAll(ownerDir)
			endpoint := filepath.Join(ownerDir, "owner.sock")
			listener, err := net.Listen("unix", endpoint)
			if err != nil { t.Fatal(err) }
			defer listener.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			owner := &Host{streams: make(map[uint64]sessionStream)}
			events := make(chan json.RawMessage, 8)
			owner.streams[1] = sessionStream{sessionID: "shared-session", frames: events}
			served := make(chan error, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil { served <- err; return }
				snapshotBusy := "false"
				if alreadyWorking { snapshotBusy = "true" }
				snapshot := json.RawMessage(fmt.Sprintf(
					`{"type":"session.snapshot","session_id":"shared-session","runtime_epoch":"go-owner-epoch","cursor":0,"high_water_cursor":0,"busy":%s}`,
					snapshotBusy,
				))
				served <- sb.ServeConn(ctx, conn,
					sb.Owner{InstanceID: "go-owner", RuntimeEpoch: "go-owner-epoch"},
					func(_ context.Context, sessionID string) (sb.Subscription, error) {
						if sessionID != "shared-session" {
							return sb.Subscription{}, fmt.Errorf("unknown Session")
						}
						return sb.Subscription{Snapshot: snapshot, Events: events}, nil
					})
			}()
			child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestGoProcessSessionBridgeViewer$")
			child.Env = append(os.Environ(),
				"CETAS_TEST_GO_BRIDGE_VIEWER=1",
				"CETAS_TEST_GO_BRIDGE_SOCKET="+endpoint,
				fmt.Sprintf("CETAS_TEST_GO_BRIDGE_BUSY=%t", alreadyWorking),
			)
			stdout, err := child.StdoutPipe()
			if err != nil { t.Fatal(err) }
			var stderr strings.Builder
			child.Stderr = &stderr
			if err := child.Start(); err != nil { t.Fatal(err) }
			lines := make(chan string, 4)
			go func() {
				scanner := bufio.NewScanner(stdout)
				for scanner.Scan() { lines <- scanner.Text() }
				close(lines)
			}()
			select {
			case line := <-lines:
				if line != "VIEWER_READY" {
					t.Fatalf("viewer did not attach: %q, stderr: %s", line, stderr.String())
				}
			case <-ctx.Done():
				t.Fatalf("viewer did not attach before deadline: %v, stderr: %s", ctx.Err(), stderr.String())
			}
			if !alreadyWorking {
				owner.publishSessionFrame("shared-session", []byte(`{"type":"turn.accepted","session_id":"shared-session","runtime_epoch":"go-owner-epoch","cursor":1,"cursor_advance":true}`))
			}
			cursor := 1
			if !alreadyWorking { cursor = 2 }
			owner.publishSessionFrame("shared-session", []byte(fmt.Sprintf(
				`{"type":"assistant.text_delta","session_id":"shared-session","runtime_epoch":"go-owner-epoch","cursor":%d,"cursor_advance":true,"delta":"Go owner live output"}`,
				cursor,
			)))
			select {
			case line := <-lines:
				if line != "VIEWER_RECEIVED" {
					t.Fatalf("viewer did not receive live output: %q, stderr: %s", line, stderr.String())
				}
			case <-ctx.Done():
				t.Fatalf("viewer did not receive live output before deadline: %v, stderr: %s", ctx.Err(), stderr.String())
			}
			if err := child.Wait(); err != nil {
				t.Fatalf("viewer process failed: %v, stderr: %s", err, stderr.String())
			}
			owner.closeSessionStreams()
			select {
			case err := <-served:
				if err != nil && !errors.Is(err, sb.ErrResnapshot) && ctx.Err() == nil {
					t.Fatalf("Posoco bridge server failed: %v", err)
				}
			case <-ctx.Done():
				t.Fatalf("Posoco bridge did not shut down: %v", ctx.Err())
			}
		})
	}
}
