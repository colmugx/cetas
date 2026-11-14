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
	kind string
	frame json.RawMessage
}

type piSupervisor struct {
	host *Host
	mu sync.Mutex
	guests map[string]*nativepi.Guest
	workers map[string]chan piGuestFrame
	generations map[string]uint64
	closed bool
}

func newPiSupervisor(host *Host) *piSupervisor {
	return &piSupervisor{host: host, guests: make(map[string]*nativepi.Guest), workers: make(map[string]chan piGuestFrame), generations: make(map[string]uint64)}
}

func (s *piSupervisor) handle(kind string, frame json.RawMessage) {
	switch kind {
	case "pi.guest.ready":
		var event struct {
			SessionID string `json:"session_id"`
			Home string `json:"home"`
			Cwd string `json:"cwd"`
		}
		if err := json.Unmarshal(frame,&event);err!=nil {s.host.report(fmt.Errorf("Pi guest ready: %w",err));return}
		go s.ready(event.SessionID,event.Home,event.Cwd)
	case "pi.guest.retired":
        var event struct { SessionID string `json:"session_id"` }
        if err := json.Unmarshal(frame,&event);err!=nil {s.host.report(fmt.Errorf("Pi guest retired: %w",err));return}
        s.retire(event.SessionID)
    case "pi.guest.execute":
		var event struct {
			SessionID string `json:"session_id"`
			RequestID string `json:"request_id"`
			ToolName string `json:"tool_name"`
			CallID string `json:"call_id"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(frame,&event);err!=nil {s.host.report(fmt.Errorf("Pi tool frame: %w",err));return}
		s.enqueue(event.SessionID, kind, frame)
	default:
		if isPiObserverFrame(kind) {
			var event struct { SessionID string `json:"session_id"` }
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
	case "turn.started", "assistant.text_delta", "tool.started",
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
		return // No guest was installed for this session.
	}
	select {
	case queue <- piGuestFrame{kind: kind, frame: append(json.RawMessage(nil), raw...)}:
	default:
		s.host.report(fmt.Errorf("Pi guest session %s event queue full", sessionID))
	}
	s.mu.Unlock()
}

// A single worker per Session owns observer/event ordering. It may call the
// Harness without blocking its EventHub pump; unrelated sessions stay live.
func (s *piSupervisor) process(sessionID string, g *nativepi.Guest, queue <-chan piGuestFrame) {
	for frame := range queue {
		if frame.kind == "pi.guest.execute" {
			var event struct {
				RequestID string `json:"request_id"`
				ToolName string `json:"tool_name"`
				CallID string `json:"call_id"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(frame.frame, &event); err != nil {
				s.host.report(fmt.Errorf("Pi execute: %w", err))
				continue
			}
			s.execute(sessionID, event.RequestID, event.ToolName, event.CallID, event.Arguments)
			continue
		}
		_, before := g.Catalog()
		if err := g.Emit(frame.frame); err != nil {
			s.host.report(err)
		}
		defs, after := g.Catalog()
		if after != before {
			if err := s.install(sessionID, defs); err != nil {
				s.host.report(fmt.Errorf("Pi observer catalog publication: %w", err))
			}
		}
	}
}

func (s *piSupervisor) ready(sessionID,home,cwd string) {
	if sessionID==""||home=="" {s.host.report(fmt.Errorf("Pi guest ready missing session identity"));return}
	select {
	case <-s.host.started:
	case <-s.host.done: return
	}
	s.mu.Lock()
	_, exists := s.guests[sessionID]
	if s.closed || exists {s.mu.Unlock();return}
	// The generation invalidates an in-flight loader when its SessionHandle
	// retires. A resumed session with the same journal id gets a new VM.
	s.generations[sessionID]++
	generation := s.generations[sessionID]
	s.guests[sessionID]=nil
	s.mu.Unlock()

	g,err:=nativepi.Open(home,cwd)
	if err!=nil {
		s.host.report(fmt.Errorf("Pi guest session %s: %w",sessionID,err))
		s.mu.Lock()
        if s.generations[sessionID] == generation { delete(s.guests,sessionID) }
        s.mu.Unlock()
		return
	}
	s.mu.Lock()
	if s.closed || s.generations[sessionID]!=generation {s.mu.Unlock();g.Close();return}
	s.guests[sessionID]=g
	queue := make(chan piGuestFrame, 256)
	s.workers[sessionID]=queue
	s.mu.Unlock()
	go s.process(sessionID, g, queue)
	defs,_:=g.Catalog()
	if len(defs)==0 {return}
	if err:=s.install(sessionID,defs);err!=nil {
		s.host.report(fmt.Errorf("Pi guest publish %s: %w",sessionID,err))
	}
}

func (s *piSupervisor) install(sessionID string,defs []nativepi.Tool) error {
	ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second)
	defer cancel()
	_,err:=s.host.Request(ctx,"pi_guest_install",map[string]any{
		"session_id":sessionID,"tools":defs,
	})
	return err
}

func (s *piSupervisor) execute(sessionID,requestID,name,callID string,arguments json.RawMessage) {
	if requestID=="" || sessionID=="" {return}
	s.mu.Lock()
	g:=s.guests[sessionID]
	s.mu.Unlock()
	result:=nativepi.Result{Content:"Native Pi guest unavailable for session "+sessionID}
	if g!=nil {
		_,before:=g.Catalog()
		result=g.Execute(name,callID,arguments)
		defs,after:=g.Catalog()
		if after!=before {
			// Publish the new revision BEFORE unblocking the effect: Posoco
			// will admit it only on a future operation.
			if err:=s.install(sessionID,defs);err!=nil {
				result=nativepi.Result{Content:"Pi tool catalog publication failed: "+err.Error()}
			}
		}
	}
	ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second)
	defer cancel()
	_,err:=s.host.Request(ctx,"pi_guest_result",map[string]any{
		"session_id":sessionID,"request_id":requestID,"result":result,
	})
	if err!=nil {s.host.report(fmt.Errorf("Pi guest effect %s: %w",requestID,err))}
}

func (s *piSupervisor) retire(sessionID string) {
    s.mu.Lock()
    s.generations[sessionID]++
    g := s.guests[sessionID]
    delete(s.guests,sessionID)
    if queue := s.workers[sessionID]; queue != nil {
        delete(s.workers,sessionID)
        close(queue)
    }
    s.mu.Unlock()
    // Never stall the EventHub pump while a foreign callback is unwinding.
    if g != nil { go g.Close() }
}

func (s *piSupervisor) close() {
	s.mu.Lock()
	if s.closed{s.mu.Unlock();return}
	s.closed=true
	guests:=s.guests
	s.guests=make(map[string]*nativepi.Guest)
	for sessionID, queue := range s.workers {
		close(queue)
		delete(s.workers, sessionID)
	}
	s.mu.Unlock()
	// Interrupt/termination belong to VM owner, never to MoonBit callbacks.
	for _,g:=range guests {if g!=nil {g.Close()}}
}
