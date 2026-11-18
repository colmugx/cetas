package localipc

import (
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	// CapabilityHealthPing is intentionally the ONLY capability advertised
	// until per-Surface authorization and command/event proxying are ready.
	CapabilityHealthPing = "health.ping"
	maxHealthPeers       = 16
	handshakeTimeout     = 5 * time.Second
	idleTimeout          = 60 * time.Second
)

// HealthService exposes only protocol discovery and a ping/pong exchange.
// It never invokes the Agent, SessionStore, approval path or command router.
// No service is created by normal Cetas startup; the opt-in Harness owner
// starts it only after the real runtime has booted.
type HealthService struct {
	listener net.Listener
	owner    OwnerInfo
	slots    chan struct{}
	closed   chan struct{}
	accepted chan struct{}
	mu       sync.Mutex
	clients  map[net.Conn]struct{}
	wg       sync.WaitGroup
	once     sync.Once
	closeErr error
}

func StartHealthService(listener net.Listener, owner OwnerInfo) (*HealthService, error) {
	if listener == nil || owner.InstanceID == "" || owner.RuntimeEpoch == "" {
		return nil, fmt.Errorf("%w: missing listener or runtime identity", ErrProtocol)
	}
	// Do not accidentally advertise session/command capabilities that this
	// service cannot honor. Future adapters must opt in to separate handlers.
	owner.Capabilities = []string{CapabilityHealthPing}
	s := &HealthService{
		listener: listener,
		owner:    owner,
		slots:    make(chan struct{}, maxHealthPeers),
		closed:   make(chan struct{}),
		accepted: make(chan struct{}),
		clients:  make(map[net.Conn]struct{}),
	}
	go s.accept()
	return s, nil
}

func (s *HealthService) accept() {
	defer close(s.accepted)
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.closed:
				return
			default:
			}
			// Do not spin on a permanently broken listener.
			return
		}
		select {
		case <-s.closed:
			_ = conn.Close()
			return
		case s.slots <- struct{}{}:
		default:
			// Bounded admission: a slow peer cannot accumulate goroutines.
			_ = conn.Close()
			continue
		}
		s.mu.Lock()
		select {
		case <-s.closed:
			s.mu.Unlock()
			<-s.slots
			_ = conn.Close()
			return
		default:
		}
		s.clients[conn] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go s.serve(conn)
	}
}

func (s *HealthService) serve(conn net.Conn) {
	defer func() {
		_ = conn.Close()
		s.mu.Lock()
		delete(s.clients, conn)
		s.mu.Unlock()
		<-s.slots
		s.wg.Done()
	}()
	if err := conn.SetDeadline(time.Now().Add(handshakeTimeout)); err != nil {
		return
	}
	codec := NewCodec(conn, conn)
	if _, err := ServerHandshake(codec, s.owner); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Time{})
	for {
		if err := conn.SetReadDeadline(time.Now().Add(idleTimeout)); err != nil {
			return
		}
		frame, err := codec.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				// Malformed or oversized frames terminate this peer, not the
				// owner's process or any other Surface.
			}
			return
		}
		_ = conn.SetReadDeadline(time.Time{})
		if err := conn.SetWriteDeadline(time.Now().Add(handshakeTimeout)); err != nil {
			return
		}
		switch frame.Type {
		case "ping":
			err = codec.Write(Envelope{Type: "pong", RequestID: frame.RequestID})
		case "goodbye":
			return
		default:
			// Fail closed until owner-side Session/Surface authorization and
			// idempotency are implemented; never proxy arbitrary commands.
			_ = codec.Write(Envelope{Type: "reject", RequestID: frame.RequestID,
				Error: "Cetas local IPC command proxy is not available"})
			return
		}
		if err != nil {
			return
		}
		_ = conn.SetWriteDeadline(time.Time{})
	}
}

// Close retires the listener and every peer before its owner's OS lease can
// be released. It is safe to invoke more than once.
func (s *HealthService) Close() error {
	if s == nil {
		return nil
	}
	s.once.Do(func() {
		close(s.closed)
		s.closeErr = s.listener.Close()
		s.mu.Lock()
		for conn := range s.clients {
			_ = conn.Close()
		}
		s.mu.Unlock()
		<-s.accepted
		s.wg.Wait()
	})
	return s.closeErr
}
