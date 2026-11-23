package harness

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/colmugx/cetas/cetas-go/nativepi"
)

// mergeCommands preserves the composed Posoco command catalog, then adds only
// descriptors registered by the Bun guest owning that exact session.
func (s *piSupervisor) mergeCommands(raw json.RawMessage) json.RawMessage {
	var envelope struct {
		SessionID string            `json:"session_id"`
		Commands  []json.RawMessage `json:"commands"`
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
		var def struct {
			ID string `json:"id"`
		}
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

type piInvokeRequest struct {
	SessionID string `json:"session_id"`
	ID        string `json:"id"`
	RequestID string `json:"request_id"`
	Arguments struct {
		Positional string `json:"_positional"`
	} `json:"arguments"`
}

func directPiInvocation(args any) (piInvokeRequest, bool) {
	if typed, ok := args.(piInvokeRequest); ok {
		return typed, utf8.ValidString(typed.SessionID) && utf8.ValidString(typed.ID) &&
			utf8.ValidString(typed.RequestID) && utf8.ValidString(typed.Arguments.Positional)
	}
	var req piInvokeRequest
	fields, ok := args.(map[string]any)
	if !ok {
		return req, args == nil
	}
	for key, value := range fields {
		var dst *string
		switch key {
		case "session_id":
			dst = &req.SessionID
		case "id":
			dst = &req.ID
		case "request_id":
			dst = &req.RequestID
		case "arguments":
			text, ok := directStringArg(value, "_positional")
			if !ok {
				return req, false
			}
			req.Arguments.Positional = text
			continue
		default:
			return req, false
		}
		if value != nil {
			text, ok := value.(string)
			if !ok || !utf8.ValidString(text) {
				return req, false
			}
			*dst = text
		}
	}
	return req, true
}

func readPiInvokeRequest(args any) (piInvokeRequest, error) {
	if req, ok := directPiInvocation(args); ok {
		return req, nil
	}
	var req piInvokeRequest
	err := decodeCommandArgs(args, &req)
	return req, err
}

// invokeCommand handles only namespaced Pi commands. Ordinary commands
// continue to the MoonBit CommandPort unchanged. The RPC runs asynchronously:
// the TUI receives an immediate ack, then a correlated command.completed event.
func (s *piSupervisor) invokeCommand(args any) (json.RawMessage, bool, error) {
	input, err := readPiInvokeRequest(args)
	if err != nil {
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
		_, toolBefore := g.Catalog()
		_, before := commander.Commands()
		if err := s.refreshModels(input.SessionID, g); err != nil {
			s.host.report(fmt.Errorf("Pi command %s model refresh: %w", input.ID, err))
		}
		outcome := commander.RunCommand(input.ID, input.Arguments.Positional)
		tools, toolAfter := g.Catalog()
		_, after := commander.Commands()
		s.mu.Lock()
		active := !s.closed && s.generations[input.SessionID] == generation && s.guests[input.SessionID] == g
		s.mu.Unlock()
		if !active {
			return
		}
		if toolAfter != toolBefore {
			if err := s.install(input.SessionID, tools); err != nil {
				outcome = nativepi.CommandOutcome{Type: "failure", Reason: "Pi tool catalog publication failed: " + err.Error()}
			}
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
