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
type piSupervisor struct {
	host *Host
	mu sync.Mutex
	guests map[string]*nativepi.Guest
	generations map[string]uint64
	closed bool
}

func newPiSupervisor(host *Host) *piSupervisor {
	return &piSupervisor{host: host, guests: make(map[string]*nativepi.Guest), generations: make(map[string]uint64)}
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
		go s.execute(event.SessionID,event.RequestID,event.ToolName,event.CallID,event.Arguments)
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
	s.mu.Unlock()
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
    s.mu.Unlock()
    if g != nil { g.Close() }
}

func (s *piSupervisor) close() {
	s.mu.Lock()
	if s.closed{s.mu.Unlock();return}
	s.closed=true
	guests:=s.guests
	s.guests=make(map[string]*nativepi.Guest)
	s.mu.Unlock()
	// Interrupt/termination belong to VM owner, never to MoonBit callbacks.
	for _,g:=range guests {if g!=nil {g.Close()}}
}
