package harness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/colmugx/cetas/cetas-go/internal/localipc"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// ErrNoForeignOwner is returned when this runtime is already the local owner,
// or there is no OS-elected owner to observe. The TUI may use its ordinary
// in-process Session switch in these cases.
var ErrNoForeignOwner = errors.New("no foreign local Session owner")

// ErrOwnerUnreachable means an independent runtime owns the journal domain
// but cannot be reached through the Session Bridge. Never fall back to a
// competing writable switch of that same Session in this case.
var ErrOwnerUnreachable = errors.New("Session owner is active but its local bridge cannot be reached")

// ObserveSession never composes an Agent or modifies Session storage. It
// returns the owner's initial authoritative snapshot and read-only event
// stream. A failed or incompatible connection is never treated as authority
// to write a Session owned by another process.
func (h *Host) ObserveSession(ctx context.Context, sessionID string) (*sb.Observer, error) {
	if sessionID == "" {
		return nil, errors.New("missing Session ID")
	}
	// Local owner already has its own EventHub; do not send the surface
	// through its own IPC socket and accidentally turn it read-only.
	if h.ownerLease != nil {
		return nil, ErrNoForeignOwner
	}
	conn, err := localipc.DialLocal(ctx, localipc.Home())
	if err == nil {
		observer, attachErr := sb.ObserveConn(ctx, conn, sessionID, "cetas-go-tui")
		if attachErr != nil {
			// The owner never composed this Session: no live writer exists,
			// so the ordinary local writable path is safe. The typed
			// sentinel must survive wrapping for the TUI fallback check.
			if errors.Is(attachErr, sb.ErrSessionNotComposed) {
				return nil, attachErr
			}
			return nil, fmt.Errorf("%w: %v", ErrOwnerUnreachable, attachErr)
		}
		return observer, nil
	}
	// Distinguish an absent owner from a live owner whose endpoint is
	// unavailable. We never delete or bypass an active owner lock.
	lease, leaseErr := localipc.Acquire(localipc.Home())
	if leaseErr == nil {
		_ = lease.Close()
		return nil, ErrNoForeignOwner
	}
	if errors.Is(leaseErr, localipc.ErrOwnerActive) {
		return nil, fmt.Errorf("%w: %v", ErrOwnerUnreachable, err)
	}
	return nil, fmt.Errorf("%w: cannot verify owner absence: %v; bridge: %v", ErrOwnerUnreachable, leaseErr, err)
}

// ReplayHost adapts one bridge replay connection to the terminal's runtime
// host shape. Only the transcript replay family is served; events and errors
// stay on the observer's own stream, so both channels here are permanently
// closed — the paged machinery never selects on them.
type ReplayHost struct {
	client *sb.ReplayClient
}

func (r *ReplayHost) Request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	if args == nil {
		args = map[string]any{}
	}
	payload, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	return r.client.Call(ctx, command, payload)
}

func (r *ReplayHost) Events() <-chan wire.Event { return nil }
func (r *ReplayHost) Errors() <-chan error      { return nil }
func (r *ReplayHost) Close(context.Context) error {
	if r == nil || r.client == nil {
		return nil
	}
	return r.client.Close()
}

// DialSessionReplay opens the observer's paged-history channel to the same
// owner the observe stream attaches to. It is only meaningful for a viewer
// without the owner lease; the owner terminal pages through its own harness.
func (h *Host) DialSessionReplay(ctx context.Context, sessionID string) (*ReplayHost, error) {
	if sessionID == "" {
		return nil, errors.New("missing Session ID")
	}
	if h.ownerLease != nil {
		return nil, ErrNoForeignOwner
	}
	conn, err := localipc.DialLocal(ctx, localipc.Home())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrOwnerUnreachable, err)
	}
	client, dialErr := sb.DialReplay(ctx, conn, sessionID, "cetas-go-tui")
	if dialErr != nil {
		return nil, fmt.Errorf("%w: %v", ErrOwnerUnreachable, dialErr)
	}
	return &ReplayHost{client: client}, nil
}
