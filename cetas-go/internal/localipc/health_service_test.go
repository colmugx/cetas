package localipc

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

type pipeListener struct {
	conns  chan net.Conn
	done   chan struct{}
	once   sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}
func (l *pipeListener) Addr() net.Addr {
	return &net.UnixAddr{Name: "in-memory-owner", Net: "unix"}
}
func (l *pipeListener) connect(t *testing.T) net.Conn {
	t.Helper()
	client, owner := net.Pipe()
	select {
	case l.conns <- owner:
		return client
	case <-l.done:
		_ = owner.Close()
		_ = client.Close()
		t.Fatal("listener already closed")
		return nil
	}
}

func TestHealthServiceProbeAndNoMutation(t *testing.T) {
	listener := newPipeListener()
	svc, err := StartHealthService(listener, OwnerInfo{
		InstanceID: "owner-A", RuntimeEpoch: "real-epoch-A",
		Capabilities: []string{"surface.attach", "event.cursor.v1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	info, err := ProbeConn(context.Background(), listener.connect(t))
	if err != nil {
		t.Fatalf("probe failed: %v", err)
	}
	if info.InstanceID != "owner-A" || info.RuntimeEpoch != "real-epoch-A" ||
		len(info.Capabilities) != 1 || info.Capabilities[0] != CapabilityHealthPing {
		t.Fatalf("untrusted capabilities or epoch: %+v", info)
	}
	conn := listener.connect(t)
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	codec := NewCodec(conn, conn)
	_, err = ClientHandshake(codec, Envelope{
		Type: "hello", Protocol: Protocol, Host: "cetas-go",
		ClientInstanceID: "mutator", Capabilities: []string{CapabilityHealthPing},
		Required: []string{CapabilityHealthPing},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := codec.Write(Envelope{Type: "request", RequestID: "mutation-1", Command: "turn.submit"}); err != nil {
		t.Fatal(err)
	}
	refusal, err := codec.Read()
	if err != nil || refusal.Type != "reject" || refusal.RequestID != "mutation-1" {
		t.Fatalf("mutation was not rejected: %+v %v", refusal, err)
	}
	if _, err := codec.Read(); !errors.Is(err, io.EOF) {
		t.Fatalf("mutation peer remained open after rejection: %v", err)
	}
	// Refusing a mutation must not kill the health service.
	if _, err := ProbeConn(context.Background(), listener.connect(t)); err != nil {
		t.Fatalf("owner died after rejected command: %v", err)
	}
}

func TestHealthServiceClosesActivePeers(t *testing.T) {
	l := newPipeListener()
	svc, err := StartHealthService(l, OwnerInfo{InstanceID: "owner", RuntimeEpoch: "epoch"})
	if err != nil { t.Fatal(err) }
	c := l.connect(t)
	defer c.Close()
	done := make(chan error, 1)
	go func() { done <- svc.Close() }()
	select {
	case err := <-done:
		if err != nil { t.Fatal(err) }
	case <-time.After(3 * time.Second):
		t.Fatal("health service close blocked on an idle handshake")
	}
	if err := svc.Close(); err != nil { t.Fatal(err) }
}

func TestHealthServiceRejectsIncompatibleHello(t *testing.T) {
	l := newPipeListener()
	svc, err := StartHealthService(l, OwnerInfo{InstanceID: "owner", RuntimeEpoch: "epoch"})
	if err != nil { t.Fatal(err) }
	defer svc.Close()
	c := l.connect(t)
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	codec := NewCodec(c,c)
	_, err = ClientHandshake(codec, Envelope{
		Type: "hello", Protocol: Protocol, Host: "go", ClientInstanceID: "bad",
		Capabilities: []string{"surface.attach"},
		Required: []string{"surface.attach"},
	})
	if !errors.Is(err, ErrProtocol) { t.Fatalf("missing capability unexpectedly accepted: %v", err) }
	if _, err := ProbeConn(context.Background(), l.connect(t)); err != nil {
		t.Fatalf("incompatible peer broke owner: %v", err)
	}
}
