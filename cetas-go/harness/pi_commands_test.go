package harness

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/colmugx/cetas/cetas-go/nativepi"
)

type piCommandFixtureGuest struct {
	commands []nativepi.Command
	generation uint64
}

func (g *piCommandFixtureGuest) Catalog() ([]nativepi.Tool, uint64) { return nil, 0 }
func (g *piCommandFixtureGuest) Emit([]byte) error { return nil }
func (g *piCommandFixtureGuest) Execute(string, string, json.RawMessage) nativepi.Result { return nativepi.Result{} }
func (g *piCommandFixtureGuest) Diagnostics() []string { return nil }
func (g *piCommandFixtureGuest) Close() {}
func (g *piCommandFixtureGuest) Commands() ([]nativepi.Command, uint64) { return g.commands, g.generation }
func (g *piCommandFixtureGuest) RunCommand(name, args string) nativepi.CommandOutcome {
	return nativepi.CommandOutcome{Type:"success", Feedback:name+"="+args}
}

func TestPiCommandsMergeWithComposedCatalogAndKeepSessionIsolation(t *testing.T) {
	host := newHost(nil)
	guest := &piCommandFixtureGuest{generation:1, commands:[]nativepi.Command{{
		ID:"pi:websearch", Label:"/pi:websearch", Description:"Web search",
		Category:"pi", CType:"action", Visible:true,
	}}}
	host.pi.guests["session-a"] = guest
	raw := json.RawMessage(`{"session_id":"session-a","commands":[{"id":"plan","visible":true}]}`)
	merged := host.pi.mergeCommands(raw)
	var got struct { SessionID string `json:"session_id"`; Commands []nativepi.Command `json:"commands"` }
	if err:=json.Unmarshal(merged,&got); err!=nil {
		t.Fatal(err)
	}
	if got.SessionID!="session-a" || len(got.Commands)!=2 ||
		got.Commands[0].ID!="plan" || got.Commands[1].ID!="pi:websearch" {
		t.Fatalf("Pi command did not extend native catalog: %s",merged)
	}
	other := json.RawMessage(`{"session_id":"session-b","commands":[{"id":"plan"}]}`)
	if merged := host.pi.mergeCommands(other); string(merged)!=string(other) {
		t.Fatalf("Pi commands leaked to another session: %s",merged)
	}
}

func TestPiCommandInvocationEmitsCorrelatedCompletion(t *testing.T) {
	host := newHost(nil)
	guest := &piCommandFixtureGuest{generation:1, commands:[]nativepi.Command{{
		ID:"pi:websearch", Visible:true,
	}}}
	host.pi.guests["session-a"] = guest
	host.pi.generations["session-a"] = 1
	response, handled, err := host.pi.invokeCommand(map[string]any{
		"session_id":"session-a", "id":"pi:websearch",
		"request_id":"c-1", "arguments":map[string]any{"_positional":"two words"},
	})
	if err != nil || !handled || !strings.Contains(string(response), "started") {
		t.Fatalf("Pi command not dispatched: %s %v %v",response,handled,err)
	}
	select {
	case frame := <-host.Events():
		if frame.Type!="command.completed" {
			t.Fatalf("Unexpected host event: %s",frame.Type)
		}
		var got struct {
			SessionID string `json:"session_id"`
			CommandID string `json:"command_id"`
			RequestID string `json:"request_id"`
			Outcome nativepi.CommandOutcome `json:"outcome"`
		}
		if err:=json.Unmarshal(frame.Raw,&got); err!=nil {
			t.Fatal(err)
		}
		if got.SessionID!="session-a" || got.CommandID!="pi:websearch" ||
			got.RequestID!="c-1" || got.Outcome.Type!="success" || got.Outcome.Feedback!="pi:websearch=two words" {
			t.Fatalf("Incorrect Pi command result: %+v",got)
		}
	case <-time.After(2*time.Second):
		t.Fatal("Pi completion never reached native TUI")
	}
	if _,handled,_ := host.pi.invokeCommand(map[string]any{"session_id":"session-a","id":"plan"}); handled {
		t.Fatal("Ordinary Posoco command was intercepted by Pi")
	}
	if _,handled,err := host.pi.invokeCommand(map[string]any{
		"session_id":"session-b","id":"pi:websearch","request_id":"c-2",
	}); !handled || err == nil {
		t.Fatal("Missing session guest was allowed to invoke a Pi command")
	}
}
