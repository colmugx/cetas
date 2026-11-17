package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/colmugx/cetas/cetas-go/nativepi"
)

// piSupervisor is the Go owner of a session's foreign JavaScript VM.
// No Javascript callback is invoked on the MoonBit scheduler thread. All
// normal tool/catalog decisions still enter the Posoco kernel through Request.
// piGuestFrame is a host-owned copy of an authoritative MoonBit EventHub frame.
// Each session serializes callback delivery and tool execution on one worker.
type piGuestFrame struct {
	kind  string
	frame json.RawMessage
}

type piSupervisor struct {
	host        *Host
	mu          sync.Mutex
	guests      map[string]nativepi.RuntimeGuest
	workers     map[string]chan piGuestFrame
	generations map[string]uint64
	closed      bool
	home        string
}

func newPiSupervisor(host *Host) *piSupervisor {
	return &piSupervisor{host: host, guests: make(map[string]nativepi.RuntimeGuest), workers: make(map[string]chan piGuestFrame), generations: make(map[string]uint64)}
}

func (s *piSupervisor) handle(kind string, frame json.RawMessage) {
	switch kind {
	case "pi.guest.ready":
		var event struct {
			SessionID string `json:"session_id"`
			Home      string `json:"home"`
			Cwd       string `json:"cwd"`
		}
		if err := json.Unmarshal(frame, &event); err != nil {
			s.host.report(fmt.Errorf("Pi guest ready: %w", err))
			return
		}
		s.beginReady(event.SessionID, event.Home, event.Cwd)
	case "pi.guest.retired":
		var event struct {
			SessionID string `json:"session_id"`
		}
		if err := json.Unmarshal(frame, &event); err != nil {
			s.host.report(fmt.Errorf("Pi guest retired: %w", err))
			return
		}
		s.retire(event.SessionID)
	case "pi.guest.execute":
		var event struct {
			SessionID string          `json:"session_id"`
			RequestID string          `json:"request_id"`
			ToolName  string          `json:"tool_name"`
			CallID    string          `json:"call_id"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(frame, &event); err != nil {
			s.host.report(fmt.Errorf("Pi tool frame: %w", err))
			return
		}
		s.enqueue(event.SessionID, kind, frame)
	default:
		if isPiObserverFrame(kind) {
			var event struct {
				SessionID string `json:"session_id"`
			}
			if err := json.Unmarshal(frame, &event); err != nil {
				s.host.report(fmt.Errorf("Pi observer frame: %w", err))
				return
			}
			s.enqueue(event.SessionID, kind, frame)
		}
	}
}

func isPiObserverFrame(kind string) bool {
	switch kind {
	case "session.switched", "turn.started", "assistant.text_delta", "tool.started",
		"tool.completed", "turn.completed", "turn.failed":
		return true
	default:
		return false
	}
}

// Keep the source EventHub order: a tool.started observer must fire before
// the tool's execute callback, even if the latter runs on another goroutine.
func (s *piSupervisor) enqueue(sessionID, kind string, raw json.RawMessage) {
	s.mu.Lock()
	queue := s.workers[sessionID]
	if queue == nil || s.closed {
		s.mu.Unlock()
		if kind == "pi.guest.execute" {
			go s.failExecution(raw, "Pi guest unavailable for session")
		}
		return
	}
	select {
	case queue <- piGuestFrame{kind: kind, frame: append(json.RawMessage(nil), raw...)}:
	default:
		s.host.report(fmt.Errorf("Pi guest session %s event queue full", sessionID))
		if kind == "pi.guest.execute" {
			go s.failExecution(raw, "Pi guest event queue full")
		}
	}
	s.mu.Unlock()
}

// A single worker per Session owns observer/event ordering. It may call the
// Harness without blocking its EventHub pump; unrelated sessions stay live.
// Tool execution requests must be answered even on queue overflow or retirement.
func (s *piSupervisor) failExecution(raw json.RawMessage, reason string) {
	var e struct {
		SessionID string `json:"session_id"`
		RequestID string `json:"request_id"`
	}
	if json.Unmarshal(raw, &e) != nil || e.SessionID == "" || e.RequestID == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err := s.host.Request(ctx, "pi_guest_result", map[string]any{
		"session_id": e.SessionID, "request_id": e.RequestID,
		"result": nativepi.Result{OK: false, Content: reason},
	})
	if err != nil {
		s.host.report(fmt.Errorf("Pi guest failed execution %s: %w", e.RequestID, err))
	}
}
func (s *piSupervisor) process(sessionID string, g nativepi.RuntimeGuest, queue <-chan piGuestFrame) {
	for frame := range queue {
		s.mu.Lock()
		active := s.guests[sessionID] == g
		s.mu.Unlock()
		if !active {
			if frame.kind == "pi.guest.execute" {
				s.failExecution(frame.frame, "Pi guest session retired")
			}
			continue
		}
		if frame.kind == "pi.guest.execute" {
			var event struct {
				RequestID string          `json:"request_id"`
				ToolName  string          `json:"tool_name"`
				CallID    string          `json:"call_id"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(frame.frame, &event); err != nil {
				s.host.report(fmt.Errorf("Pi execute: %w", err))
				continue
			}
			s.execute(g, sessionID, event.RequestID, event.ToolName, event.CallID, event.Arguments)
			continue
		}
		_, before := g.Catalog()
		var beforeCommands uint64
		if commander, ok := g.(nativepi.Commander); ok {
			_, beforeCommands = commander.Commands()
		}
		if err := g.Emit(frame.frame); err != nil {
			s.host.report(err)
		}
		defs, after := g.Catalog()
		if after != before {
			if err := s.install(sessionID, defs); err != nil {
				s.host.report(fmt.Errorf("Pi observer catalog publication: %w", err))
			}
		}
		if commander, ok := g.(nativepi.Commander); ok {
			_, afterCommands := commander.Commands()
			if afterCommands != beforeCommands {
				s.notifyCommandsChanged(sessionID)
			}
		}
	}
}

// Reserve a generation on the ordered EventHub pump before asynchronous IO.
func (s *piSupervisor) beginReady(sessionID, home, cwd string) {
	if sessionID == "" || home == "" {
		s.host.report(fmt.Errorf("Pi guest ready missing session identity"))
		return
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.home = home
	if !s.host.piAvailable {
		s.mu.Unlock()
		return
	}
	if _, exists := s.guests[sessionID]; exists {
		s.mu.Unlock()
		return
	}
	s.generations[sessionID]++
	gen := s.generations[sessionID]
	s.guests[sessionID] = nil
	s.mu.Unlock()
	go s.ready(sessionID, home, cwd, gen)
}

// moejs remains available as a lazy lightweight runtime for future
// bunraku work, but is never initialized by the native Pi adaptor.
func (s *piSupervisor) openGuest(home, cwd string) (nativepi.RuntimeGuest, error) {
	if !s.host.piAvailable {
		return nil, fmt.Errorf("native Pi requires Bun Runtime; enable it in /experimental and restart")
	}
	path, ready, err := bunPrepared(home)
	if err != nil {
		return nil, err
	}
	if !ready {
		return nil, fmt.Errorf("Bun Runtime not installed; open /experimental")
	}
	return nativepi.OpenBun(path, home, cwd)
}

func (s *piSupervisor) ready(sessionID, home, cwd string, generation uint64) {
	select {
	case <-s.host.started:
	case <-s.host.done:
		return
	}
	g, err := s.openGuest(home, cwd)
	if err != nil {
		s.host.report(fmt.Errorf("Pi guest session %s: %w", sessionID, err))
		s.mu.Lock()
		if s.generations[sessionID] == generation {
			delete(s.guests, sessionID)
		}
		s.mu.Unlock()
		return
	}
	if err := s.refreshModels(sessionID, g); err != nil {
		s.host.report(fmt.Errorf("Pi guest session %s: %w", sessionID, err))
	}
	for _, diagnostic := range g.Diagnostics() {
		s.host.report(fmt.Errorf("Pi guest session %s: %s", sessionID, diagnostic))
	}
	s.mu.Lock()
	if s.closed || s.generations[sessionID] != generation {
		s.mu.Unlock()
		g.Close()
		return
	}
	s.guests[sessionID] = g
	queue := make(chan piGuestFrame, 256)
	s.workers[sessionID] = queue
	s.mu.Unlock()
	go s.process(sessionID, g, queue)
	if commander, ok := g.(nativepi.Commander); ok {
		commands, _ := commander.Commands()
		if len(commands) > 0 {
			s.notifyCommandsChanged(sessionID)
		}
	}
	defs, _ := g.Catalog()
	if len(defs) == 0 {
		return
	}
	if err := s.install(sessionID, defs); err != nil {
		s.host.report(fmt.Errorf("Pi guest publish %s: %w", sessionID, err))
	}
}

// refreshModels asks the authoritative session's ModelPort for public picker
// metadata. Never forward tokens, auth configuration, or a guessed model.
func (s *piSupervisor) refreshModels(sessionID string, guest nativepi.RuntimeGuest) error {
	updater, ok := guest.(interface{ UpdateModels(json.RawMessage) error })
	if !ok {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	raw, err := s.host.Request(ctx, "models", map[string]any{"session_id": sessionID})
	if err != nil {
		return fmt.Errorf("native model snapshot: %w", err)
	}
	var identity struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(raw, &identity); err != nil {
		return fmt.Errorf("native model snapshot identity: %w", err)
	}
	if identity.SessionID != sessionID {
		return fmt.Errorf("native model snapshot belongs to session %q, expected %q", identity.SessionID, sessionID)
	}
	if err := updater.UpdateModels(raw); err != nil {
		return fmt.Errorf("Pi model snapshot: %w", err)
	}
	return nil
}

func (s *piSupervisor) install(sessionID string, defs []nativepi.Tool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err := s.host.Request(ctx, "pi_guest_install", map[string]any{
		"session_id": sessionID, "tools": defs,
	})
	return err
}

func (s *piSupervisor) execute(g nativepi.RuntimeGuest, sessionID, requestID, name, callID string, arguments json.RawMessage) {
	if requestID == "" || sessionID == "" {
		return
	}
	// The worker carries the guest identity that received this obligation.
	// Never redirect a late request to a newly opened VM for the same session.
	result := nativepi.Result{Content: "Native Pi guest unavailable for session " + sessionID}
	if g != nil {
		_, before := g.Catalog()
		if err := s.refreshModels(sessionID, g); err != nil {
			s.host.report(fmt.Errorf("Pi guest session %s model refresh: %w", sessionID, err))
		}
		result = g.Execute(name, callID, arguments)
		defs, after := g.Catalog()
		if after != before {
			// Publish the new revision BEFORE unblocking the effect: Posoco
			// will admit it only on a future operation.
			if err := s.install(sessionID, defs); err != nil {
				result = nativepi.Result{Content: "Pi tool catalog publication failed: " + err.Error()}
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err := s.host.Request(ctx, "pi_guest_result", map[string]any{
		"session_id": sessionID, "request_id": requestID, "result": result,
	})
	if err != nil {
		s.host.report(fmt.Errorf("Pi guest effect %s: %w", requestID, err))
	}
}

func (s *piSupervisor) retire(sessionID string) {
	s.mu.Lock()
	s.generations[sessionID]++
	g := s.guests[sessionID]
	delete(s.guests, sessionID)
	if queue := s.workers[sessionID]; queue != nil {
		delete(s.workers, sessionID)
		close(queue)
	}
	s.mu.Unlock()
	// Never stall the EventHub pump while a foreign callback is unwinding.
	if g != nil {
		go g.Close()
	}
}

func (s *piSupervisor) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	guests := s.guests
	s.guests = make(map[string]nativepi.RuntimeGuest)
	for sessionID, queue := range s.workers {
		close(queue)
		delete(s.workers, sessionID)
	}
	s.mu.Unlock()
	// Interrupt/termination belong to VM owner, never to MoonBit callbacks.
	for _, g := range guests {
		if g != nil {
			g.Close()
		}
	}
}
