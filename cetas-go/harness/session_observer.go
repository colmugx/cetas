package harness

import (
    "context"
    "errors"
    "fmt"

    "github.com/colmugx/cetas/cetas-go/internal/localipc"
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
    if sessionID == "" { return nil, errors.New("missing Session ID") }
    // Local owner already has its own EventHub; do not send the surface
    // through its own IPC socket and accidentally turn it read-only.
    if h.ownerLease != nil { return nil, ErrNoForeignOwner }
    conn, err := localipc.DialLocal(ctx, localipc.Home())
    if err == nil {
        observer, attachErr := sb.ObserveConn(ctx, conn, sessionID, "cetas-go-tui")
        if attachErr != nil {
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
