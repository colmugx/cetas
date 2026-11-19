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

// ObserveSession reads an already composed Session from its existing Go or
// Bun owner. It never creates a competing Agent, writes a journal, or blindly
// retries a mutation.
func (h *Host) ObserveSession(ctx context.Context, sessionID string) (*wire.SessionObservation, error) {
	if sessionID == "" {
		return nil, fmt.Errorf("empty Session ID")
	}
	home := localipc.Home()
	var attempts []func(context.Context, string) (net.Conn, error)
	if h.ownerContended {
		attempts = append(attempts, localipc.DialLocal)
	}
	if localipc.BunOwnerAvailable(home) {
		attempts = append(attempts, localipc.DialBunOwner)
	}
	if len(attempts) == 0 {
		return nil, fmt.Errorf("no competing local Session owner to observe")
	}

	var observer *sb.Observer
	var lastErr error
	for _, dial := range attempts {
		conn, err := dial(ctx, home)
		if err != nil {
			lastErr = err
			continue
		}
		var identity [16]byte
		if _, err := rand.Read(identity[:]); err != nil {
			_ = conn.Close()
			return nil, err
		}
		observer, err = sb.ObserveConn(ctx, conn, sessionID, hex.EncodeToString(identity[:]))
		if err == nil {
			break
		}
		lastErr = err
	}
	if observer == nil {
		return nil, fmt.Errorf("existing owner refused Session %s: %w", sessionID, lastErr)
	}
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
				// Slow viewers must resnapshot rather than lose a cursor,
				// and can never stall the existing owner Runtime.
				return
			}
		}
	}()
	return &wire.SessionObservation{
		Snapshot: append(json.RawMessage(nil), observer.Snapshot...),
		Events:   events,
		Close:    closeObserver,
	}, nil
}
