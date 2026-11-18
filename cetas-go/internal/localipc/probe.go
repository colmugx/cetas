package localipc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"time"
)

// ProbeLocal checks an optional owner without creating state, acquiring a
// lease or composing an Agent. It is never required for ordinary startup.
func ProbeLocal(ctx context.Context, home string) (OwnerInfo, error) {
	conn, err := DialLocal(ctx, home)
	if err != nil {
		return OwnerInfo{}, err
	}
	return ProbeConn(ctx, conn)
}

// ProbeConn consumes the supplied connection, including on failure. It
// explicitly requires the read-only health capability and verifies ping/pong;
// a reachable but incompatible endpoint is not treated as a usable owner.
func ProbeConn(ctx context.Context, conn net.Conn) (OwnerInfo, error) {
	defer conn.Close()
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return OwnerInfo{}, fmt.Errorf("mint IPC probe identity: %w", err)
	}
	deadline := time.Now().Add(handshakeTimeout)
	if userDeadline, ok := ctx.Deadline(); ok && userDeadline.Before(deadline) {
		deadline = userDeadline
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return OwnerInfo{}, err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	codec := NewCodec(conn, conn)
	hello := Envelope{
		Type: "hello", Protocol: Protocol, Host: "cetas-go",
		ClientInstanceID: hex.EncodeToString(id),
		Capabilities: []string{CapabilityHealthPing},
		Required: []string{CapabilityHealthPing},
	}
	welcome, err := ClientHandshake(codec, hello)
	if err != nil {
		return OwnerInfo{}, err
	}
	if err := codec.Write(Envelope{Type: "ping", RequestID: "probe"}); err != nil {
		return OwnerInfo{}, err
	}
	reply, err := codec.Read()
	if err != nil {
		return OwnerInfo{}, err
	}
	if reply.Type != "pong" || reply.RequestID != "probe" {
		return OwnerInfo{}, fmt.Errorf("%w: invalid owner probe response", ErrProtocol)
	}
	return OwnerInfo{
		InstanceID: welcome.OwnerInstanceID, RuntimeEpoch: welcome.RuntimeEpoch,
		Capabilities: welcome.Capabilities,
	}, nil
}
