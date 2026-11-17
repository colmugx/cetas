package localipc

import (
	"errors"
	"fmt"
)

// OwnerInfo is supplied by the actual runtime host, not minted by the
// transport. In particular the epoch must be the EventHub's runtime epoch.
type OwnerInfo struct {
	InstanceID   string
	RuntimeEpoch string
	Capabilities []string
}

func negotiate(hello Envelope, owner OwnerInfo) (Envelope, error) {
	if hello.Type != "hello" || hello.Protocol != Protocol ||
		hello.Host == "" || hello.ClientInstanceID == "" {
		return Envelope{}, fmt.Errorf("%w: unsupported hello or protocol", ErrProtocol)
	}
	if owner.InstanceID == "" || owner.RuntimeEpoch == "" {
		return Envelope{}, fmt.Errorf("%w: owner has no runtime identity", ErrProtocol)
	}
	available := make(map[string]bool, len(owner.Capabilities))
	for _, capability := range owner.Capabilities {
		if capability != "" {
			available[capability] = true
		}
	}
	intersection := make([]string, 0, len(hello.Capabilities))
	seen := make(map[string]bool)
	for _, capability := range hello.Capabilities {
		if available[capability] && !seen[capability] {
			intersection = append(intersection, capability)
			seen[capability] = true
		}
	}
	for _, required := range hello.Required {
		if !seen[required] {
			return Envelope{}, fmt.Errorf("%w: required capability %q unavailable", ErrProtocol, required)
		}
	}
	return Envelope{
		Type: "welcome", Protocol: Protocol,
		OwnerInstanceID: owner.InstanceID, RuntimeEpoch: owner.RuntimeEpoch,
		Capabilities: intersection, MaxFrameSize: MaxFrameSize,
	}, nil
}

// ServerHandshake either writes one welcome frame or a typed refusal. A
// refused connection must be closed; it must never dispatch a runtime command.
func ServerHandshake(codec *Codec, owner OwnerInfo) (Envelope, error) {
	hello, err := codec.Read()
	if err != nil {
		return Envelope{}, err
	}
	welcome, err := negotiate(hello, owner)
	if err != nil {
		_ = codec.Write(Envelope{Type: "reject", Error: err.Error()})
		return Envelope{}, err
	}
	if err := codec.Write(welcome); err != nil {
		return Envelope{}, err
	}
	return hello, nil
}

// ClientHandshake prevents any command dispatch before protocol and capability
// negotiation succeeds. A rejected handshake cannot fall back to local Agent
// composition; the caller must explicitly handle owner unavailability.
func ClientHandshake(codec *Codec, hello Envelope) (Envelope, error) {
	if hello.Type != "hello" || hello.Protocol != Protocol ||
		hello.Host == "" || hello.ClientInstanceID == "" {
		return Envelope{}, fmt.Errorf("%w: incomplete client hello", ErrProtocol)
	}
	if err := codec.Write(hello); err != nil {
		return Envelope{}, err
	}
	reply, err := codec.Read()
	if err != nil {
		return Envelope{}, err
	}
	if reply.Type == "reject" {
		return Envelope{}, fmt.Errorf("%w: %s", ErrProtocol, reply.Error)
	}
	if reply.Type != "welcome" || reply.Protocol != Protocol ||
		reply.OwnerInstanceID == "" || reply.RuntimeEpoch == "" ||
		reply.MaxFrameSize <= 0 || reply.MaxFrameSize > MaxFrameSize {
		return Envelope{}, fmt.Errorf("%w: malformed owner welcome", ErrProtocol)
	}
	capabilities := make(map[string]bool, len(reply.Capabilities))
	for _, c := range reply.Capabilities {
		capabilities[c] = true
	}
	for _, required := range hello.Required {
		if !capabilities[required] {
			return Envelope{}, fmt.Errorf("%w: owner omitted required capability %q", ErrProtocol, required)
		}
	}
	return reply, nil
}

// Keep this sentinel available for errors.Is-based refusal paths.
var ErrOwnerProtocol = errors.Join(ErrProtocol, errors.New("local IPC owner protocol mismatch"))
