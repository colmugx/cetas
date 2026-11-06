// Package harness is the Go host-side command/event adapter for the
// statically linked MoonBit Cetas runtime. It contains no UI or transport
// server. One MoonBit scheduler owns all Cetas objects on its locked OS thread.
package harness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	bridge "github.com/colmugx/cetas/cetas-native/go_bridge"
)

var (
	ErrAlreadyStarted = errors.New("the MoonBit Harness process has already been started")
	ErrBackpressure   = errors.New("Harness EventHub consumer is not draining its bounded queue")
	ErrClosed         = errors.New("native Harness stopped")
	activated         atomic.Bool
)

// Event contains a full, unmodified EventHub frame (not a Go reinterpretation).
// Harness responses are matched by ID and are not delivered on Events.
type Event struct {
	Type string
	Raw  json.RawMessage
}

type envelope struct {
	ID      uint64 `json:"id"`
	Command string `json:"command"`
	Args    any    `json:"args"`
}

// transport is the native boundary a Host drives. It is an interface so
// failure-path tests can inject a fake instead of starting a second
// process-singleton MoonBit runtime; *bridge.Infra is the only
// production implementation.
type transport interface {
	Run() int
	Send(code int32) error
	Poll() ([]byte, error)
	DroppedEvents() int
	Rejections() bridge.Rejections
	Submit(request []byte) error
}

// rejectionsDelta reports what changed since the pump last acted, clamping
// at zero so counters can only ever move forward.
func rejectionsDelta(current, seen bridge.Rejections) bridge.Rejections {
	delta := bridge.Rejections{
		Oversized:  current.Oversized - seen.Oversized,
		Allocation: max(0, current.Allocation-seen.Allocation),
		QueueFull:  current.QueueFull - seen.QueueFull,
		Invalid:    current.Invalid - seen.Invalid,
	}
	if delta.Oversized < 0 {
		delta.Oversized = 0
	}
	if delta.QueueFull < 0 {
		delta.QueueFull = 0
	}
	if delta.Invalid < 0 {
		delta.Invalid = 0
	}
	return delta
}

type Host struct {
	infra     transport
	nextID    atomic.Uint64
	mu        sync.Mutex
	pending   map[uint64]chan json.RawMessage
	events    chan Event
	problems  chan error
	boot      chan Event
	done      chan struct{}
	exited    chan struct{}
	exitCode  int
	closeOnce sync.Once
	stopped   bool
	// cause keeps the first fatal reason the runtime stopped answering.
	// The problems channel is best-effort and closes with the pump, so a
	// later Request must still be able to say why the harness died
	// instead of reporting a bare ErrClosed.
	causeMu sync.Mutex
	cause   error
}

func newHost(infra transport) *Host {
	return &Host{
		infra:    infra,
		pending:  make(map[uint64]chan json.RawMessage),
		events:   make(chan Event, 256),
		problems: make(chan error, 1),
		boot:     make(chan Event, 1),
		done:     make(chan struct{}),
		exited:   make(chan struct{}),
	}
}

// launch starts the runtime owner and the event pump; it is the only place
// besides tests that runs them.
func (h *Host) launch() {
	go func() {
		h.exitCode = h.infra.Run()
		close(h.exited)
	}()
	go h.pump()
}

// fail records the first fatal cause and reports it. Every later
// stoppedErr carries this cause, so the reason the runtime died survives
// the problems channel being drained or closed.
func (h *Host) fail(err error) {
	if err == nil {
		return
	}
	h.causeMu.Lock()
	if h.cause == nil {
		if detail, ok := h.infra.(interface{ RejectionContext() string }); ok && h.infra.DroppedEvents() > 0 {
			err = fmt.Errorf("%w; %s", err, detail.RejectionContext())
		}
		h.cause = err
	}
	h.causeMu.Unlock()
	h.report(err)
}

// stoppedErr explains why a request cannot be served. The first fatal
// cause wins over the bare sentinel, and errors.Is(err, ErrClosed) holds
// either way.
func (h *Host) stoppedErr() error {
	h.causeMu.Lock()
	defer h.causeMu.Unlock()
	if h.cause != nil {
		return fmt.Errorf("%w: %s", ErrClosed, h.cause)
	}
	return ErrClosed
}

// Start composes a real ConsoleRuntime. The caller must consume Events.
// The process is intentionally single-use until restart safety is proven.
func Start(ctx context.Context) (*Host, error) {
	if !activated.CompareAndSwap(false, true) {
		return nil, ErrAlreadyStarted
	}
	h := newHost(bridge.NewInfra())
	h.launch()
	return h.awaitBoot(ctx)
}

// awaitBoot waits for the runtime's first lifecycle frame.
func (h *Host) awaitBoot(ctx context.Context) (*Host, error) {
	select {
	case evt := <-h.boot:
		var v struct {
			Status string `json:"status"`
			Detail string `json:"detail"`
		}
		if err := json.Unmarshal(evt.Raw, &v); err != nil {
			_ = h.Close(ctx)
			return nil, fmt.Errorf("invalid Harness boot: %w", err)
		}
		if v.Status != "ready" {
			_ = h.Close(ctx)
			return nil, fmt.Errorf("Cetas startup: %s: %s", v.Status, v.Detail)
		}
		return h, nil
	case <-ctx.Done():
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.Close(cleanup)
		return nil, ctx.Err()
	case <-h.done:
		return nil, h.stoppedErr()
	}
}

// Events contains all real EventHub payloads plus lifecycle frames.
// The consuming MyGo adapter must feed them into Window.Update.
func (h *Host) Events() <-chan Event { return h.events }
func (h *Host) Errors() <-chan error { return h.problems }

func (h *Host) report(err error) {
	select {
	case h.problems <- err:
	default:
	}
}

// Request correlates a command to its response even with concurrent callers.
// All bytes are copied into native C memory; no Go pointers are retained.
func (h *Host) Request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	if command == "" {
		return nil, errors.New("empty Harness command")
	}
	id := h.nextID.Add(1)
	if id >= 1<<53 {
		return nil, errors.New("request id precision limit reached")
	}
	req, err := json.Marshal(envelope{ID: id, Command: command, Args: args})
	if err != nil {
		return nil, err
	}
	answer := make(chan json.RawMessage, 1)
	h.mu.Lock()
	if h.stopped {
		h.mu.Unlock()
		return nil, h.stoppedErr()
	}
	h.pending[id] = answer
	h.mu.Unlock()
	defer func() { h.mu.Lock(); delete(h.pending, id); h.mu.Unlock() }()
	ticker := time.NewTicker(2 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = h.infra.Submit(req)
		if err == nil {
			break
		}
		if !errors.Is(err, bridge.ErrQueueFull) {
			// Native framing rejected this frame itself (for example a
			// command over 256 KiB): name the request and the rejection
			// reason instead of dropping it as a bare sentinel.
			return nil, fmt.Errorf("harness command %q rejected: %w", command, err)
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("%w: harness command %q was never accepted, the native command queue stayed full", ctx.Err(), command)
		case <-h.done:
			return nil, h.stoppedErr()
		case <-ticker.C:
		}
	}
	select {
	case response := <-answer:
		var e struct {
			Error string `json:"error"`
		}
		if err := json.Unmarshal(response, &e); err == nil && e.Error != "" {
			return response, errors.New(e.Error)
		}
		return response, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-h.done:
		return nil, h.stoppedErr()
	}
}

func (h *Host) pump() {
	defer close(h.done)
	defer close(h.events)
	defer close(h.problems)
	ticker := time.NewTicker(2 * time.Millisecond)
	defer ticker.Stop()
	// seen holds the rejection counts the pump already acted on; the native
	// counters are cumulative, so only deltas are new information.
	seen := bridge.Rejections{}
	for {
		payload, err := h.infra.Poll()
		if rej := h.infra.Rejections(); rej != seen {
			delta := rejectionsDelta(rej, seen)
			seen = rej
			if detail, ok := h.infra.(interface{ RejectionContext() string }); ok {
				h.report(fmt.Errorf("native EventHub rejection diagnostics: %s", detail.RejectionContext()))
			}
			switch {
			case delta.Oversized > 0:
				h.fail(fmt.Errorf("native framing rejected %d oversized EventHub frame(s) over the %d MiB chunked-frame limit: the bounded transport carries at most %d bytes per frame as %d KiB chunks", delta.Oversized, bridge.FrameLimit>>20, bridge.FrameLimit, bridge.ChunkLimit>>10))
				_ = h.infra.Send(bridge.CommandStop)
				return
			case delta.Invalid > 0:
				h.fail(fmt.Errorf("native framing rejected %d EventHub frame(s): the runtime published a null or empty frame", delta.Invalid))
				_ = h.infra.Send(bridge.CommandStop)
				return
			case delta.Allocation > 0:
				h.fail(fmt.Errorf("native EventHub allocation failed for %d frame(s)", delta.Allocation))
				_ = h.infra.Send(bridge.CommandStop)
				return
			case delta.QueueFull > 0:
				// Delivery was lost after the bounded native wait expired.
				// Continuing would leave requests hung and the UI divergent.
				h.fail(fmt.Errorf("native EventHub queue full after waiting 2s: rejected %d frame(s) at the %d-chunk/%d MiB bound", delta.QueueFull, bridge.QueueFrameCap, bridge.QueueByteCap>>20))
				_ = h.infra.Send(bridge.CommandStop)
				return
			}
		}
		if err != nil {
			h.fail(err)
			_ = h.infra.Send(bridge.CommandStop)
			return
		}
		if len(payload) == 0 {
			select {
			case <-h.exited:
				h.fail(fmt.Errorf("MoonBit scheduler exited: code=%d", h.exitCode))
				return
			case <-ticker.C:
			}
			continue
		}
		var tag struct {
			Type   string          `json:"type"`
			ID     uint64          `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if err := json.Unmarshal(payload, &tag); err != nil {
			h.report(fmt.Errorf("bad EventHub frame: %w", err))
			continue
		}
		if tag.Type == "harness.response" {
			h.mu.Lock()
			answer := h.pending[tag.ID]
			h.mu.Unlock()
			if answer != nil {
				select {
				case answer <- append(json.RawMessage(nil), tag.Result...):
				default:
				}
			}
			continue
		}
		evt := Event{Type: tag.Type, Raw: append(json.RawMessage(nil), payload...)}
		if tag.Type == "infra.boot" {
			select {
			case h.boot <- evt:
			default:
			}
		}
		select {
		case h.events <- evt:
		default:
			h.fail(ErrBackpressure)
			_ = h.infra.Send(bridge.CommandStop)
			return
		}
		if tag.Type == "infra.stopped" {
			return
		}
	}
}

// Close asks the MoonBit TaskGroup to drain, detaches EventHub and waits for
// its OS-thread owner to exit. Call before MyGo terminates its main loop.
func (h *Host) Close(ctx context.Context) error {
	h.closeOnce.Do(func() {
		h.mu.Lock()
		h.stopped = true
		h.mu.Unlock()
		// Stop has a dedicated existing low-latency queue. In a saturated
		// command queue, the consumer must drain before we retry.
		go func() {
			for {
				if err := h.infra.Send(bridge.CommandStop); err == nil {
					return
				}
				select {
				case <-h.exited:
					return
				case <-time.After(5 * time.Millisecond):
				}
			}
		}()
	})
	select {
	case <-h.exited:
		<-h.done
		if h.exitCode != 1 {
			return fmt.Errorf("MoonBit Harness exited with code %d", h.exitCode)
		}
		if n := h.infra.DroppedEvents(); n != 0 {
			r := h.infra.Rejections()
			return fmt.Errorf("MoonBit EventHub lost %d frames (%d oversized, %d queue full, %d invalid, %d allocation failed)", n, r.Oversized, r.QueueFull, r.Invalid, r.Allocation)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
