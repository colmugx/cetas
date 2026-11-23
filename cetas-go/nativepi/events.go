package nativepi

import (
	"encoding/json"
	"fmt"
)

type nativeFrame struct {
	Type             string          `json:"type"`
	ToolCallID       string          `json:"tool_call_id"`
	ParentToolCallID string          `json:"parent_tool_call_id"`
	ToolName         string          `json:"tool_name"`
	Arguments        json.RawMessage `json:"arguments"`
	Result           string          `json:"result"`
	IsError          bool            `json:"is_error"`
	Delta            string          `json:"delta"`
	Text             string          `json:"text"`
}

type EventBridge struct {
	turnIndex      int
	runActive      bool
	messageStarted bool
	text           string
	toolResults    []any
	runMessages    []any
	lastAssistant  map[string]any
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
	case "session.switched":
		// Cetas can switch the active session tree without starting a model
		// turn. Reset Pi extension branch-local state on that real boundary.
		return []PiEvent{emit("session_tree", nil)}, nil
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
		b.lastAssistant = nil
		b.toolResults = nil
		return append(out, emit("turn_start", PiEvent{
			"turnIndex": b.turnIndex,
		})), nil
	case "assistant.text_delta":
		var out []PiEvent
		if !b.messageStarted {
			// A new model message after a tool wave begins a new response.
			b.lastAssistant = nil
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
		var out []PiEvent
		if b.lastAssistant == nil {
			// A tool-only model reply has no text_delta. Pi still requires
			// message_start before its message_end and tool callbacks.
			if !b.messageStarted {
				out = append(out, emit("message_start", PiEvent{"message": b.message("pending")}))
			}
			b.lastAssistant = b.message("toolUse")
			b.runMessages = append(b.runMessages, b.lastAssistant)
			out = append(out, emit("message_end", PiEvent{
				"message": b.lastAssistant,
			}))
			b.messageStarted = false
			b.text = ""
		}
		// Pi's tool_call hook is raised before the tool_execution_start
		// observer. This native EventHub boundary is observational (the
		// kernel has already admitted the call), so extension callbacks
		// cannot block, change arguments, or grant permissions here.
		call := PiEvent{
			"toolCallId": frame.ToolCallID, "toolName": frame.ToolName, "input": args,
		}
		if frame.ParentToolCallID != "" {
			call["parentToolCallId"] = frame.ParentToolCallID
		}
		out = append(out, emit("tool_call", call))
		return append(out, emit("tool_execution_start", PiEvent{
			"toolCallId": frame.ToolCallID, "toolName": frame.ToolName, "args": args,
		})), nil
	case "tool.completed":
		toolResult := map[string]any{
			"role":       "toolResult",
			"toolCallId": frame.ToolCallID,
			"toolName":   frame.ToolName,
			"content":    []any{map[string]any{"type": "text", "text": frame.Result}},
			"isError":    frame.IsError,
		}
		b.toolResults = append(b.toolResults, toolResult)
		b.runMessages = append(b.runMessages, toolResult)
		return []PiEvent{emit("tool_execution_end", PiEvent{
			"toolCallId": frame.ToolCallID, "toolName": frame.ToolName,
			"result": frame.Result, "isError": frame.IsError,
		})}, nil
	case "turn.completed":
		var out []PiEvent
		message := b.lastAssistant
		if b.messageStarted || message == nil {
			if !b.messageStarted && b.text == "" {
				b.text = frame.Text
			}
			message = b.message("stop")
			out = append(out, emit("message_end", PiEvent{"message": message}))
			b.runMessages = append(b.runMessages, message)
		}
		out = append(out, emit("turn_end", PiEvent{
			"turnIndex": b.turnIndex, "message": message,
			"toolResults": append([]any{}, b.toolResults...),
		}))
		b.turnIndex++
		b.messageStarted = false
		b.text = ""
		b.toolResults = nil
		b.lastAssistant = nil
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
		// Failure is a terminal turn too: settle every passive observer
		// in order so extension state cannot remain permanently active.
		var out []PiEvent
		message := b.lastAssistant
		if b.messageStarted || message == nil {
			if !b.messageStarted {
				out = append(out, emit("message_start", PiEvent{"message": b.message("pending")}))
			}
			message = b.message("error")
			out = append(out, emit("message_end", PiEvent{"message": message}))
			b.runMessages = append(b.runMessages, message)
		}
		out = append(out, emit("turn_end", PiEvent{
			"turnIndex": b.turnIndex, "message": message,
			"toolResults": append([]any{}, b.toolResults...),
		}))
		out = append(out, emit("agent_end", PiEvent{"messages": append([]any{}, b.runMessages...)}))
		out = append(out, emit("agent_settled", nil))
		b.runActive = false
		b.messageStarted = false
		b.text = ""
		b.toolResults = nil
		b.lastAssistant = nil
		b.runMessages = nil
		return out, nil
	default:
		return nil, nil
	}
}

func (b *EventBridge) message(reason string) map[string]any {
	return map[string]any{
		"role":       "assistant",
		"content":    []any{map[string]any{"type": "text", "text": b.text}},
		"stopReason": reason,
	}
}
