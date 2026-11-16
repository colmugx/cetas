package harness

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/colmugx/cetas/cetas-go/nativepi"
)

// mergeCommands preserves the composed Posoco command catalog, then adds only
// descriptors registered by the Bun guest owning that exact session.
func (s *piSupervisor) mergeCommands(raw json.RawMessage) json.RawMessage {
	var envelope struct {
		SessionID string             `json:"session_id"`
		Commands  []json.RawMessage  `json:"commands"`
	}
	if json.Unmarshal(raw, &envelope) != nil || envelope.SessionID == "" {
		return raw
	}
	s.mu.Lock()
	g := s.guests[envelope.SessionID]
	s.mu.Unlock()
	commander, ok := g.(nativepi.Commander)
	if !ok {
		return raw
	}
	commands, _ := commander.Commands()
	seen := make(map[string]bool, len(envelope.Commands))
	for _, item := range envelope.Commands {
		var def struct { ID string `json:"id"` }
		if json.Unmarshal(item, &def) == nil {
			seen[strings.ToLower(def.ID)] = true
		}
	}
	for _, def := range commands {
		if def.ID == "" || seen[strings.ToLower(def.ID)] {
			continue
		}
		item, err := json.Marshal(def)
		if err == nil {
			envelope.Commands = append(envelope.Commands, item)
			seen[strings.ToLower(def.ID)] = true
		}
	}
	merged, err := json.Marshal(envelope)
	if err != nil {
		return raw
	}
	return merged
}

// invokeCommand handles only namespaced Pi commands. Ordinary commands
// continue to the MoonBit CommandPort unchanged. The RPC runs asynchronously:
// the TUI receives an immediate ack, then a correlated command.completed event.
func (s *piSupervisor) invokeCommand(args any) (json.RawMessage, bool, error) {
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, false, err
	}
	var input struct {
		SessionID string `json:"session_id"`
		ID        string `json:"id"`
		RequestID string `json:"request_id"`
		Arguments struct {
			Positional string `json:"_positional"`
		} `json:"arguments"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, false, err
	}
	if !strings.HasPrefix(input.ID, "pi:") {
		return nil, false, nil
	}
	if input.SessionID == "" || input.RequestID == "" {
		return nil, true, fmt.Errorf("Pi invocation requires session_id and request_id")
	}
	s.mu.Lock()
	g := s.guests[input.SessionID]
	generation := s.generations[input.SessionID]
	closed := s.closed
	s.mu.Unlock()
	commander, ok := g.(nativepi.Commander)
	if closed || !ok {
		return nil, true, fmt.Errorf("Pi guest unavailable for session %s", input.SessionID)
	}
	commands, _ := commander.Commands()
	exists := false
	for _, def := range commands {
		if def.ID == input.ID {
			exists = true
			break
		}
	}
	if !exists {
		return nil, true, fmt.Errorf("Pi command not registered: %s", input.ID)
	}
	go func() {
		_, before := commander.Commands()
		outcome := commander.RunCommand(input.ID, input.Arguments.Positional)
		_, after := commander.Commands()
		s.mu.Lock()
		active := !s.closed && s.generations[input.SessionID] == generation && s.guests[input.SessionID] == g
		s.mu.Unlock()
		if !active {
			return
		}
		if after != before {
			s.notifyCommandsChanged(input.SessionID)
		}
		s.publishCommandOutcome(input.SessionID, input.ID, input.RequestID, outcome)
	}()
	return json.RawMessage(`{"status":"started"}`), true, nil
}

func (s *piSupervisor) publishCommandOutcome(sessionID, id, requestID string, outcome nativepi.CommandOutcome) {
	payload, err := json.Marshal(map[string]any{
		"type": "command.completed", "session_id": sessionID,
		"command_id": id, "request_id": requestID, "outcome": outcome,
	})
	if err != nil {
		s.host.report(err)
		return
	}
	s.publishPiEvent("command.completed", payload)
}

func (s *piSupervisor) notifyCommandsChanged(sessionID string) {
	payload, err := json.Marshal(map[string]any{
		"type": "pi.commands.changed", "session_id": sessionID,
	})
	if err == nil {
		s.publishPiEvent("pi.commands.changed", payload)
	}
}

func (s *piSupervisor) publishPiEvent(kind string, payload json.RawMessage) {
	select {
	case s.host.events <- Event{Type: kind, Raw: payload}:
	default:
		s.host.report(fmt.Errorf("Pi %s: UI event queue full", kind))
	}
}
