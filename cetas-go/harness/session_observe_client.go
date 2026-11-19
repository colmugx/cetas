package harness

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"sync"

	"github.com/colmugx/cetas/cetas-go/internal/localipc"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// ObserveSession attaches read-only to a Session currently held in the
// already-running local Owner. It never loads a journal, starts an Agent, or
// retries a command. The caller owns the returned stream and must Close it.
func (h *Host) ObserveSession(ctx context.Context, sessionID string) (*wire.SessionObservation, error) {
	if sessionID == "" {
		return nil, fmt.Errorf("empty Session ID")
	}
	home := localipc.Home()
	var attempts []func(context.Context,string)(net.Conn,error)
	if h.ownerContended {
		attempts=append(attempts,localipc.DialLocal)
	}
	if localipc.BunOwnerAvailable(home) {
		attempts=append(attempts,localipc.DialBunOwner)
	}
	if len(attempts)==0 {
		return nil,fmt.Errorf("no competing local Session owner to observe")
	}
	var observer *sb.Observer
	var lastErr error
	for _,dial:=range attempts {
		conn,err:=dial(ctx,home)
		if err!=nil {lastErr=err;continue}
		events := make(chan wire.Event, 128)
	closed := make(chan struct{})
	var once sync.Once
	closeObserver := func() error {
		var closeErr error
		once.Do(func() {
			close(closed)
			closeErr = observer.Close()
		})
		return closeErr
	}
	go func() {
		defer close(events)
		defer closeObserver()
		for {
			raw, err := observer.Next()
			if err != nil {
				// A transport failure must stop the read-only stream. It
				// cannot silently create a new writer for the same Session.
				return
			}
			var tag struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(raw, &tag) != nil || tag.Type == "" {
				return
			}
			frame := wire.Event{Type: tag.Type, Raw: append(json.RawMessage(nil), raw...)}
			select {
			case events <- frame:
			case <-closed:
				return
			default:
				// Slow UI: retire the view instead of dropping a cursor
				// while claiming event continuity.
				return
			}
		}
	}()
	return &wire.SessionObservation{
		Snapshot: append(json.RawMessage(nil), observer.Snapshot...),
		Events: events,
		Close: closeObserver,
	}, nil
}
