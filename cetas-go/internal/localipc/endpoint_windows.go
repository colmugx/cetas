//go:build windows

package localipc

import (
	"context"
	"errors"
	"net"
)

// Windows transport must be a same-user-SID ACL-protected named pipe, not
// loopback TCP or a socket emulation. The named-pipe adapter is a subsequent
// slice; fail closed until it has its own Windows CI and security tests.
var ErrNamedPipePending = errors.New("Cetas Windows named-pipe transport not implemented")

func ListenLocal(_ *Lease) (net.Listener, error) {
	return nil, ErrNamedPipePending
}

func DialLocal(_ context.Context, _ string) (net.Conn, error) {
	return nil, ErrNamedPipePending
}
