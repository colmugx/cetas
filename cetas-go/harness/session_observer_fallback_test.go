package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	bridge "github.com/colmugx/cetas/cetas-go/go_bridge"
	"github.com/colmugx/cetas/cetas-go/internal/localipc"
	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// refusalTransport answers the first harness request with one canned result
// frame carrying the request's own correlation id. It serves exactly the
// native boundary the refusal mapping needs: Submit -> Poll -> response.
type refusalTransport struct {
	mu        sync.Mutex
	reply     json.RawMessage
	pending   []byte
	submitted chan struct{}
	served    chan struct{}
	subOnce   sync.Once
	srvOnce   sync.Once
}

// Run stays alive until the canned reply has been handed to the pump, so the
// pump never mistakes a served exchange for a dead scheduler.
func (f *refusalTransport) Run() int { <-f.served; return 0 }
func (f *refusalTransport) Send(int32) error { return nil }
func (f *refusalTransport) Poll() ([]byte, error) {
	<-f.submitted
	f.mu.Lock()
	frame := f.pending
	f.pending = nil
	f.mu.Unlock()
	f.srvOnce.Do(func() { close(f.served) })
	return frame, nil
}
func (f *refusalTransport) Wait() error { <-f.submitted; return nil }
func (f *refusalTransport) Wake() error { return nil }
func (f *refusalTransport) DroppedEvents() int { return 0 }
func (f *refusalTransport) Rejections() bridge.Rejections { return bridge.Rejections{} }
func (f *refusalTransport) Submit(request []byte) error {
	var envelope struct {
		ID uint64 `json:"id"`
	}
	if err := json.Unmarshal(request, &envelope); err != nil {
		return err
	}
	frame, err := json.Marshal(map[string]any{
		"type":   "harness.response",
		"id":     envelope.ID,
		"result": f.reply,
	})
	if err != nil {
		return err
	}
	f.mu.Lock()
	f.pending = frame
	f.mu.Unlock()
	f.subOnce.Do(func() { close(f.submitted) })
	return nil
}

// The owner host must translate the runtime's machine-readable refusal into
// the typed bridge error so the reject frame tells viewers a local writable
// fallback is safe.
func TestSubscribeSessionMapsNotComposedRefusal(t *testing.T) {
	tr := &refusalTransport{
		reply:     json.RawMessage(`{"error":"Session is not composed in this Runtime","code":"session_not_composed"}`),
		submitted: make(chan struct{}),
		served:    make(chan struct{}),
	}
	h := newHost(tr)
	h.launch()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = h.Close(ctx)
	}()
	_, err := h.subscribeSession(context.Background(), "never-composed")
	if !errors.Is(err, sb.ErrSessionNotComposed) {
		t.Fatalf("typed refusal lost between runtime and bridge: %v", err)
	}
}

// Runs in a second OS process of the same test executable: a real viewer
// dialing the owner's actual localipc socket.
func TestGoProcessViewerNotComposingFallback(t *testing.T) {
	if os.Getenv("CETAS_TEST_GO_FALLBACK_VIEWER") != "1" {
		return
	}
	h := newHost(nil)
	ctx, cancel := context.WithTimeout(context.Background(), 9*time.Second)
	defer cancel()
	_, err := h.ObserveSession(ctx, "uncomposed-session")
	if !errors.Is(err, sb.ErrSessionNotComposed) {
		t.Fatalf("viewer did not receive the typed refusal: %v", err)
	}
	fmt.Println("VIEWER_TYPED_REFUSAL")
}

// An owner process that never composed the requested Session must refuse
// with the typed code over the real transport, and the viewer-side error
// must unwrap to the sentinel — the exact contract the TUI fallback uses.
func TestGoOwnerNotComposingRefusesTypedOverRealSocket(t *testing.T) {
	if os.Getenv("CETAS_TEST_GO_FALLBACK_VIEWER") == "1" {
		return
	}
	if os.PathSeparator != '/' {
		t.Skip("Unix-socket process acceptance; Windows named-pipe tests are separate")
	}
	home, err := os.MkdirTemp("", "cetas-fallback-home-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	lease, err := localipc.Acquire(home)
	if err != nil {
		t.Fatalf("acquire owner lease: %v", err)
	}
	listener, err := localipc.ListenLocal(lease)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	served := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			served <- acceptErr
			return
		}
		served <- sb.ServeConn(ctx, conn,
			sb.Owner{InstanceID: "go-owner", RuntimeEpoch: "go-owner-epoch"},
			func(_ context.Context, sessionID string) (sb.Subscription, error) {
				return sb.Subscription{}, fmt.Errorf(
					"%w: Session is not composed in this Runtime",
					sb.ErrSessionNotComposed,
				)
			})
	}()
	child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestGoProcessViewerNotComposingFallback$")
	child.Env = append(os.Environ(),
		"CETAS_TEST_GO_FALLBACK_VIEWER=1",
		"CETAS_HOME="+home,
	)
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr strings.Builder
	child.Stderr = &stderr
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	lines := make(chan string, 4)
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
		close(lines)
	}()
	select {
	case line := <-lines:
		if line != "VIEWER_TYPED_REFUSAL" {
			t.Fatalf("viewer outcome unexpected: %q, stderr: %s", line, stderr.String())
		}
	case <-ctx.Done():
		t.Fatalf("viewer did not settle before deadline: %v, stderr: %s", ctx.Err(), stderr.String())
	}
	if err := child.Wait(); err != nil {
		t.Fatalf("viewer process failed: %v, stderr: %s", err, stderr.String())
	}
	_ = listener.Close()
	_ = lease.Close()
	// The lease must be reusable the moment the owner retires it.
	again, err := localipc.Acquire(home)
	if err != nil {
		t.Fatalf("lease not released after owner exit: %v", err)
	}
	_ = again.Close()
}
