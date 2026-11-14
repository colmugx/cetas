package nativepi

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/MoeForge/moejs"
)

// Exactly the passive observer events supported by the cetas-js Pi adaptor.
// Mutation hooks such as before_agent_start or context are intentionally
// rejected rather than being accepted but never called.
func supportedPiEvent(name string) bool {
	switch name {
	case "agent_start", "agent_end", "agent_settled",
		"turn_start", "turn_end", "message_start", "message_update",
		"message_end", "tool_execution_start", "tool_execution_end":
		return true
	default:
		return false
	}
}

type nativeFrame struct {
	Type       string          `json:"type"`
	ToolCallID string          `json:"tool_call_id"`
	ToolName   string          `json:"tool_name"`
	Arguments  json.RawMessage `json:"arguments"`
	Result     string          `json:"result"`
	IsError    bool            `json:"is_error"`
	Delta      string          `json:"delta"`
	Text       string          `json:"text"`
}

type EventBridge struct {
	turnIndex      int
	runActive      bool
	messageStarted bool
	text           string
	toolResults    []any
	runMessages    []any
}

// PiEvent is the original Pi observer's (event, context) payload; the type
// field uses Pi names rather than Cetas EventHub wire event names.
type PiEvent map[string]any

func (b *EventBridge) Translate(raw []byte) ([]PiEvent, error) {
	var frame nativeFrame
	if err := json.Unmarshal(raw, &frame); err != nil {
		return nil, fmt.Errorf("Pi event frame: %w", err)
	}
	emit := func(name string, data PiEvent) PiEvent {
		if data == nil {
			data = PiEvent{}
		}
		data["type"] = name
		return data
	}
	switch frame.Type {
	case "turn.started":
		var out []PiEvent
		if !b.runActive {
			b.runActive = true
			b.turnIndex = 0
			b.runMessages = nil
			out = append(out, emit("agent_start", nil))
		}
		b.messageStarted = false
		b.text = ""
		b.toolResults = nil
		return append(out, emit("turn_start", PiEvent{
			"turnIndex": b.turnIndex,
		})), nil
	case "assistant.text_delta":
		var out []PiEvent
		if !b.messageStarted {
			b.messageStarted = true
			out = append(out, emit("message_start", PiEvent{
				"message": b.message("pending"),
			}))
		}
		b.text += frame.Delta
		return append(out, emit("message_update", PiEvent{
			"message": b.message("pending"),
			"assistantMessageEvent": map[string]any{
				"type": "text_delta", "contentIndex": 0, "delta": frame.Delta,
			},
		})), nil
	case "tool.started":
		var args any = map[string]any{}
		if len(frame.Arguments) > 0 && string(frame.Arguments) != "null" {
			if err := json.Unmarshal(frame.Arguments, &args); err != nil {
				return nil, fmt.Errorf("Pi tool arguments: %w", err)
			}
		}
		return []PiEvent{emit("tool_execution_start", PiEvent{
			"toolCallId": frame.ToolCallID, "toolName": frame.ToolName, "args": args,
		})}, nil
	case "tool.completed":
		toolResult := map[string]any{
			"role": "toolResult",
			"toolCallId": frame.ToolCallID,
			"toolName": frame.ToolName,
			"content": []any{map[string]any{"type": "text", "text": frame.Result}},
			"isError": frame.IsError,
		}
		b.toolResults = append(b.toolResults, toolResult)
		b.runMessages = append(b.runMessages, toolResult)
		return []PiEvent{emit("tool_execution_end", PiEvent{
			"toolCallId": frame.ToolCallID, "toolName": frame.ToolName,
			"result": frame.Result, "isError": frame.IsError,
		})}, nil
	case "turn.completed":
		var out []PiEvent
		message := b.message("stop")
		if b.messageStarted {
			out = append(out, emit("message_end", PiEvent{"message": message}))
		}
		b.runMessages = append(b.runMessages, message)
		out = append(out, emit("turn_end", PiEvent{
			"turnIndex": b.turnIndex, "message": message,
			"toolResults": append([]any{}, b.toolResults...),
		}))
		b.turnIndex++
		b.messageStarted = false
		b.text = ""
		b.toolResults = nil
		// Cetas marks the end of an admitted operation as its Agent
		// boundary. This does not claim parity with Pi's queued follow-ups.
		if b.runActive {
			out = append(out, emit("agent_end", PiEvent{
				"messages": append([]any{}, b.runMessages...),
			}))
			out = append(out, emit("agent_settled", nil))
			b.runActive = false
			b.runMessages = nil
		}
		return out, nil
	case "turn.failed":
		b.runActive = false
		b.messageStarted = false
		b.text = ""
		b.toolResults = nil
		b.runMessages = nil
		return []PiEvent{emit("agent_end", PiEvent{"messages": []any{}})}, nil
	default:
		return nil, nil
	}
}

func (b *EventBridge) message(reason string) map[string]any {
	return map[string]any{
		"role": "assistant",
		"content": []any{map[string]any{"type": "text", "text": b.text}},
		"stopReason": reason,
	}
}

// Dispatch is run under Guest.mu so handlers, tool execution and shutdown
// never access a single moejs VM concurrently. Handler failures are surfaced
// to the supervisor; never kill the Posoco run loop.
func (g *Guest) dispatch(events []PiEvent) error {
	for _, event := range events {
		name, _ := event["type"].(string)
		for _, entry := range g.entries {
			for _, handler := range entry.handlers[name] {
				if err := entry.loop.Run(func(rt *moejs.Runtime) error {
					payload, err := rt.FromGo(map[string]any(event))
					if err != nil {
						return err
					}
					ctx, err := rt.FromGo(map[string]any{
						"cwd": g.cwd, "hasUI": false, "mode": "json",
					})
					if err != nil {
						return err
					}
					result, err := rt.CallFunction(handler, moejs.Undefined(), payload, ctx)
					if err != nil {
						return err
					}
					if state, value, ok := moejs.PromiseResult(result); ok {
						switch state {
						case moejs.PromiseRejected:
							return fmt.Errorf("handler rejected: %s", value.String())
						case moejs.PromisePending:
							return errors.New("async observer did not settle")
						}
					}
					return nil
				}); err != nil {
					return fmt.Errorf("Pi event %s: %w", name, err)
				}
			}
		}
	}
	return nil
}

// Emit consumes one authoritative EventHub frame; it never mutates Posoco's
// session journal or fabricates an Agent operation.
func (g *Guest) Emit(raw []byte) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.names == nil {
		return errors.New("Pi guest was retired")
	}
	events, err := g.events.Translate(raw)
	if err != nil {
		return err
	}
	return g.dispatch(events)
}
