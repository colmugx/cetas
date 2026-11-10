package harness

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	bridge "github.com/colmugx/cetas/cetas-native/go_bridge"
)

// fakeTransport replays the native boundary's failure modes for the real
// pump and Request code. The production *bridge.Infra cannot serve a second
// test: the MoonBit runtime is a process singleton, so failure paths would
// otherwise be untestable once TestNativeHarnessHost has started it.
type fakeTransport struct {
	mu          sync.Mutex
	payload     [][]byte          // frames Poll returns, in order, then none
	pollErr     error             // Poll's answer once the queued frames drain
	queue       func() error      // decides each Submit result
	drops       int               // DroppedEvents' answer
	rejects     bridge.Rejections // Rejections' cumulative answer
	run         chan struct{}     // closed to release Run; nil returns at once
	runOnce     sync.Once
	afterSubmit bool // hold queued frames until the first Submit
	submitted   chan struct{}
	subOnce     sync.Once
	// waitCh, when set, stands in for the native notification pipe: Wait
	// blocks on it until Wake rings, exactly as the real transport does. A
	// nil channel keeps the short re-check interval the older failure-path
	// tests rely on.
	waitCh chan struct{}
	polls  int
}

func (f *fakeTransport) Run() int {
	if f.run != nil {
		<-f.run
	}
	return 0
}

func (f *fakeTransport) Send(int32) error { return nil }

func (f *fakeTransport) Poll() ([]byte, error) {
	f.mu.Lock()
	hasPayload := len(f.payload) > 0
	gate := f.submitted
	f.mu.Unlock()
	if hasPayload && f.afterSubmit && gate != nil {
		// Request registers its pending answer before it submits, so a
		// replayed reply can never race ahead of its waiter.
		<-gate
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.polls++
	if len(f.payload) > 0 {
		next := f.payload[0]
		f.payload = f.payload[1:]
		return next, nil
	}
	return nil, f.pollErr
}

// Wait mirrors the native notification pipe when a test asks for it: the pump
// blocks here until Wake rings, so an idle host does no work at all.
func (f *fakeTransport) Wait() error {
	f.mu.Lock()
	ch := f.waitCh
	f.mu.Unlock()
	if ch != nil {
		<-ch
		return nil
	}
	time.Sleep(time.Millisecond)
	return nil
}

// Wake is the host-side doorbell: the pump's runtime owner rings it as it
// exits, and tests ring it after publishing diagnostics outside the queue.
func (f *fakeTransport) Wake() error {
	f.mu.Lock()
	ch := f.waitCh
	f.mu.Unlock()
	if ch == nil {
		return nil
	}
	select {
	case ch <- struct{}{}:
	default:
	}
	return nil
}

// pollCount reports how often the pump actually polled the queue.
func (f *fakeTransport) pollCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.polls
}

func (f *fakeTransport) DroppedEvents() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.drops
}

// Production transports attach diagnostics to the same fatal error. Exercise
// that path too: a separate diagnostic must not occupy the one-slot error feed.
func (f *fakeTransport) RejectionContext() string { return "fixture rejection context" }

func (f *fakeTransport) Rejections() bridge.Rejections {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rejects
}

func (f *fakeTransport) setRejections(r bridge.Rejections) {
	f.mu.Lock()
	f.rejects = r
	f.mu.Unlock()
}

// bumpQueueFull grows only the queue-full counter, the way the real native
// layer does when a burst hits the bounded event queue.
func (f *fakeTransport) bumpQueueFull(n int32) {
	f.mu.Lock()
	f.rejects.QueueFull += n
	f.drops += int(n)
	f.mu.Unlock()
}

func (f *fakeTransport) Submit([]byte) error {
	f.subOnce.Do(func() {
		f.mu.Lock()
		if f.submitted == nil {
			f.submitted = make(chan struct{})
		}
		gate := f.submitted
		f.mu.Unlock()
		close(gate)
	})
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.queue == nil {
		return nil
	}
	return f.queue()
}

func (f *fakeTransport) failWith(err error) {
	f.mu.Lock()
	f.pollErr = err
	f.mu.Unlock()
}

func (f *fakeTransport) release() {
	f.runOnce.Do(func() {
		if f.run != nil {
			close(f.run)
		}
	})
}

// newFatalHost wires and launches a host over the fake, the same way Start
// does, and stops it when the test ends.
func newFatalHost(t *testing.T, tr *fakeTransport) *Host {
	t.Helper()
	tr.mu.Lock()
	if tr.submitted == nil {
		tr.submitted = make(chan struct{}) // Poll may capture the gate before any Submit
	}
	tr.mu.Unlock()
	h := newHost(tr)
	h.launch()
	t.Cleanup(func() {
		tr.release()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.Close(ctx)
	})
	return h
}

func waitStopped(t *testing.T, h *Host) {
	t.Helper()
	select {
	case <-h.done:
	case <-time.After(10 * time.Second):
		t.Fatal("host pump did not stop")
	}
}

// The first fatal must reach every later Request: the problems channel is
// best-effort and closes with the pump, so a bare ErrClosed here is what
// hides the root cause from the person who sees "native Harness stopped".
func TestRequestSurfacesFirstFatalCause(t *testing.T) {
	// Run blocks until cleanup, so before the injected fault the pump can
	// only idle: the first request's success is deterministic.
	tr := &fakeTransport{
		run:         make(chan struct{}),
		afterSubmit: true,
		payload: [][]byte{
			[]byte(`{"type":"harness.response","id":1,"result":{"status":"ok"}}`),
		},
	}
	fatal := errors.New("native EventHub frame exceeds 256 KiB limit")
	h := newFatalHost(t, tr)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := h.Request(ctx, "health", map[string]any{}); err != nil {
		t.Fatalf("first request must succeed before the fault: %v", err)
	}
	tr.failWith(fatal)
	waitStopped(t, h)
	_, err := h.Request(ctx, "health", map[string]any{})
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed after the pump died, got %v", err)
	}
	if !strings.Contains(err.Error(), fatal.Error()) {
		t.Fatalf("later Request lost the first fatal cause: %v", err)
	}
}

// A frame the native boundary rejects for its own reason (over 256 KiB) is
// never silently dropped: the caller learns which command and why.
func TestFramingRejectionNamesCommandAndReason(t *testing.T) {
	tr := &fakeTransport{queue: func() error { return bridge.ErrHarnessTooLarge }}
	h := newFatalHost(t, tr)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := h.Request(ctx, "switch_session", map[string]any{})
	if !errors.Is(err, bridge.ErrHarnessTooLarge) {
		t.Fatalf("rejection must keep the framing sentinel, got %v", err)
	}
	if !strings.Contains(err.Error(), `"switch_session"`) {
		t.Fatalf("rejection must name the rejected command: %v", err)
	}
}

// The old pump blamed every drop on "a frame exceeded 256 KiB or the native
// event queue was full". A rejection beyond the reassembly limit must now be
// named as oversized, with the exact limit, and stay fatal.
func TestOversizedRejectionIsNamedExactly(t *testing.T) {
	tr := &fakeTransport{run: make(chan struct{})}
	h := newFatalHost(t, tr)
	tr.setRejections(bridge.Rejections{Oversized: 1})
	waitStopped(t, h)
	select {
	case err := <-h.Errors():
		if !strings.Contains(err.Error(), "oversized") || !strings.Contains(err.Error(), "4 MiB") {
			t.Fatalf("oversized rejection lost its exact cause and limit: %v", err)
		}
		if errors.Is(err, ErrBackpressure) {
			t.Fatalf("a native framing rejection is not Go-side backpressure: %v", err)
		}
	default:
		t.Fatal("oversized rejection was never reported")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := h.Request(ctx, "health", map[string]any{})
	if !errors.Is(err, ErrClosed) || !strings.Contains(err.Error(), "oversized") {
		t.Fatalf("later Request must carry the exact oversized cause: %v", err)
	}
}

// A null or empty publish is a runtime bug, not backpressure: fatal and named.
func TestInvalidRejectionIsFatalAndNamed(t *testing.T) {
	tr := &fakeTransport{run: make(chan struct{})}
	h := newFatalHost(t, tr)
	tr.setRejections(bridge.Rejections{Invalid: 2})
	waitStopped(t, h)
	select {
	case err := <-h.Errors():
		if !strings.Contains(err.Error(), "null or empty") || !strings.Contains(err.Error(), "2") {
			t.Fatalf("invalid rejection lost its exact cause: %v", err)
		}
	default:
		t.Fatal("invalid rejection was never reported")
	}
}

// The pump used to wake up every 2ms forever, polling an empty native queue
// (and allocating a 16 KiB scratch buffer each time). With the notification
// channel it must sleep until a producer signals.
func TestIdlePumpSleepsUntilNotified(t *testing.T) {
	tr := &fakeTransport{run: make(chan struct{}), waitCh: make(chan struct{}, 1)}
	h := newFatalHost(t, tr)
	time.Sleep(60 * time.Millisecond)
	if polls := tr.pollCount(); polls > 3 {
		t.Fatalf("idle pump polled %d times in 60ms; it must block in Wait", polls)
	}
	// A diagnostic published outside the queue still reaches the pump, but
	// only because it rings the doorbell: nothing else wakes it.
	tr.setRejections(bridge.Rejections{Invalid: 1})
	if err := tr.Wake(); err != nil {
		t.Fatal(err)
	}
	waitStopped(t, h)
	select {
	case err := <-h.Errors():
		if !strings.Contains(err.Error(), "null or empty") {
			t.Fatalf("woken pump lost the rejection cause: %v", err)
		}
	default:
		t.Fatal("invalid rejection was never reported after the wakeup")
	}
}

// The scheduler owner rings the doorbell as it exits, so a pump asleep in Wait
// wakes and reports why the runtime stopped instead of hanging.
func TestOwnerExitWakesSleepingPump(t *testing.T) {
	tr := &fakeTransport{run: make(chan struct{}), waitCh: make(chan struct{}, 1)}
	h := newFatalHost(t, tr)
	time.Sleep(20 * time.Millisecond)
	if polls := tr.pollCount(); polls > 3 {
		t.Fatalf("pump woke %d times before the owner exited; it must sleep", polls)
	}
	tr.release() // the owner returns: Run exits, then Wake rings the doorbell
	waitStopped(t, h)
	select {
	case err := <-h.Errors():
		if !strings.Contains(err.Error(), "scheduler exited") {
			t.Fatalf("exit wake lost its cause: %v", err)
		}
	default:
		t.Fatal("scheduler exit was not reported")
	}
}
