package nativepi

import (
	"reflect"
	"testing"
)

func TestPiEventBridgeOrderAndPayload(t *testing.T) {
	b := &EventBridge{}
	frames := []string{
		`{"type":"turn.started"}`,
		`{"type":"assistant.text_delta","delta":"hi"}`,
		`{"type":"tool.started","tool_call_id":"call1","tool_name":"echo","arguments":{"count":2}}`,
		`{"type":"tool.completed","tool_call_id":"call1","tool_name":"echo","result":"ok"}`,
		`{"type":"turn.completed","text":"hi"}`,
	}
	var names []string
	for _, frame := range frames {
		events, err := b.Translate([]byte(frame))
		if err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			names = append(names, event["type"].(string))
			if event["type"] == "tool_execution_start" {
				args, ok := event["args"].(map[string]any)
				if !ok || args["count"] != float64(2) {
					t.Fatalf("lost tool arguments: %#v", event)
				}
			}
		}
	}
	want := []string{"agent_start", "turn_start", "message_start",
		"message_update", "message_end", "tool_call", "tool_execution_start",
		"tool_execution_end", "turn_end", "agent_end", "agent_settled"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("event order\n got: %v\nwant: %v", names, want)
	}
}

func TestPiToolCallObservationCarriesNestedParent(t *testing.T) {
	b := &EventBridge{}
	if _, err := b.Translate([]byte(`{"type":"turn.started"}`)); err != nil {
		t.Fatal(err)
	}
	events, err := b.Translate([]byte(`{"type":"tool.started","tool_call_id":"nested-1","parent_tool_call_id":"outer-1","tool_name":"web_search","arguments":{"query":"cetas"}}`))
	if err != nil {
		t.Fatal(err)
	}
	var callIndex, execIndex = -1, -1
	for i, event := range events {
		switch event["type"] {
		case "tool_call":
			callIndex = i
			if event["toolCallId"] != "nested-1" || event["parentToolCallId"] != "outer-1" ||
				event["toolName"] != "web_search" {
				t.Fatalf("invalid nested Pi tool_call: %#v", event)
			}
			input, ok := event["input"].(map[string]any)
			if !ok || input["query"] != "cetas" {
				t.Fatalf("lost Pi tool_call input: %#v", event)
			}
		case "tool_execution_start":
			execIndex = i
		}
	}
	if callIndex < 0 || execIndex <= callIndex {
		t.Fatalf("Pi tool_call must precede execution observer: %#v", events)
	}
}

func TestPiToolOnlyReplyHasMessageStart(t *testing.T) {
	b := &EventBridge{}
	frames := []string{
		`{"type":"turn.started"}`,
		`{"type":"tool.started","tool_call_id":"x","tool_name":"echo","arguments":{}}`,
		`{"type":"tool.completed","tool_call_id":"x","tool_name":"echo","result":"ok"}`,
		`{"type":"turn.completed"}`,
	}
	var names []string
	for _, frame := range frames {
		got, err := b.Translate([]byte(frame))
		if err != nil {
			t.Fatal(err)
		}
		for _, evt := range got {
			names = append(names, evt["type"].(string))
		}
	}
	want := []string{"agent_start", "turn_start", "message_start", "message_end", "tool_call", "tool_execution_start", "tool_execution_end", "turn_end", "agent_end", "agent_settled"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("tool-only events: %v want %v", names, want)
	}
}

func TestPiFailedTurnSettlesAgent(t *testing.T) {
	b := &EventBridge{}
	for _, frame := range []string{`{"type":"turn.started"}`, `{"type":"assistant.text_delta","delta":"partial"}`} {
		if _, err := b.Translate([]byte(frame)); err != nil {
			t.Fatal(err)
		}
	}
	got, err := b.Translate([]byte(`{"type":"turn.failed"}`))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, evt := range got {
		names = append(names, evt["type"].(string))
	}
	want := []string{"message_end", "turn_end", "agent_end", "agent_settled"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("failed-turn events: %v want %v", names, want)
	}
}
