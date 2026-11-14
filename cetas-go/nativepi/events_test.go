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
	want := []string{"agent_start","turn_start","message_start",
		"message_update","tool_execution_start","tool_execution_end",
		"message_end","turn_end","agent_end","agent_settled"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("event order\n got: %v\nwant: %v", names, want)
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
		"tool_execution_start|echo:2|tool_execution_end|",
		"message_end|turn_end|agent_end|agent_settled",
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
	_, err := Open(home, home)
	if err == nil || !strings.Contains(err.Error(), "before_agent_start") {
		t.Fatalf("must reject unsupported Pi hook, got %v", err)
	}
}
