package nativepi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const lifecycleFixture = `export default function(pi) {
  const log = [];
  for (const event of ["agent_start","turn_start","message_start",
    "message_update","tool_execution_start","tool_execution_end",
    "message_end","turn_end","agent_end","agent_settled"]) {
    pi.on(event, (e) => { log.push(e.type); });
  }
  pi.on("tool_execution_start", (e) => {
    log.push(e.toolName + ":" + e.args.count);
  });
  pi.registerTool({
    name: "event_log", description: "Read event callbacks",
    parameters: {type:"object",properties:{}},
    async execute() {
      return {content:[{type:"text",text:log.join("|")}]};
    }
  });
}`

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

func TestPiGuestObserverHandlersAgainstUnmodifiedExtension(t *testing.T) {
	home, dir := writeFixture(t)
	if err := os.WriteFile(filepath.Join(dir, "index.mjs"), []byte(lifecycleFixture), 0600); err != nil {
		t.Fatal(err)
	}
	g, err := Open(home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	frames := []string{
		`{"type":"turn.started"}`,
		`{"type":"assistant.text_delta","delta":"hello"}`,
		`{"type":"tool.started","tool_call_id":"call1","tool_name":"echo","arguments":{"count":2}}`,
		`{"type":"tool.completed","tool_call_id":"call1","tool_name":"echo","result":"ok"}`,
		`{"type":"turn.completed","text":"hello"}`,
	}
	for _, frame := range frames {
		if err := g.Emit([]byte(frame)); err != nil {
			t.Fatal(err)
		}
	}
	result := g.Execute("event_log", "call2", json.RawMessage(`{}`))
	if !result.OK {
		t.Fatalf("Pi observer tool failed: %#v", result)
	}
	for _, expected := range []string{
		"agent_start|turn_start|message_start|message_update|",
		"message_end|tool_execution_start|echo:2|tool_execution_end|",
		"turn_end|agent_end|agent_settled",
	} {
		if !strings.Contains(result.Content, expected) {
			t.Fatalf("missing sequence %q: %s", expected, result.Content)
		}
	}
}

func TestPiUnsupportedMutatingHookIsRejected(t *testing.T) {
	home, dir := writeFixture(t)
	code := `export default function(pi) { pi.on("before_agent_start", () => {}); }`
	if err := os.WriteFile(filepath.Join(dir, "index.mjs"), []byte(code), 0600); err != nil {
		t.Fatal(err)
	}
	g, err := Open(home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	defs, _ := g.Catalog()
	if len(defs) != 0 {
		t.Fatal("unsupported hook registered tools")
	}
	if diagnostics := strings.Join(g.Diagnostics(), "\n"); !strings.Contains(diagnostics, "before_agent_start") {
		t.Fatalf("must report unsupported Pi hook, got %s", diagnostics)
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
