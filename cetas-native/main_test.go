package main

import (
 "encoding/json"
 "strings"
 "testing"

 "github.com/colmugx/cetas/cetas-native/harness"
)

func event(raw string) harness.Event {
 return harness.Event{Raw:json.RawMessage(raw)}
}
func TestStreamingTurnSettlesOnce(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"turn.started","session_id":"s-1"}`))
 m.applyEvent(event(`{"type":"assistant.text_delta","delta":"hello "}`))
 m.applyEvent(event(`{"type":"assistant.text_delta","delta":"world"}`))
 if !m.running || m.streaming.String()!="hello world" {t.Fatalf("streaming state: %#v",m)}
 m.applyEvent(event(`{"type":"turn.completed","text":"hello world"}`))
 if m.running || len(m.transcript)!=1 || m.transcript[0]!="hello world" {t.Fatalf("settled transcript: %#v",m.transcript)}
 if m.streaming.Len()!=0 {t.Fatal("live text not cleared")}
}
func TestFailedTurnDoesNotKeepStreamingState(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"turn.started"}`))
 m.applyEvent(event(`{"type":"assistant.text_delta","delta":"partial"}`))
 m.applyEvent(event(`{"type":"turn.failed","message":"cancelled"}`))
 if m.running || m.streaming.Len()!=0 || !strings.Contains(strings.Join(m.transcript,"\n"),"cancelled") {t.Fatalf("failed state: %#v",m.transcript)}
}
func TestEditorResizesForSmallTerminal(t *testing.T) {
 m:=newModel();m.width=18;m.height=6;m.resize()
 if m.viewport.Height()<1 || m.viewport.Width()<20 {t.Fatalf("bad dimensions: %d x %d",m.viewport.Width(),m.viewport.Height())}
}

func TestUiRequestModalUsesWireRequestID(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-7","kind":"select","prompt":"Choose","options":["one","two"]}`))
 if m.modal!="select"||m.modalRequestID!="u-7"||len(m.modalItems)!=2 {
  t.Fatalf("UI request was not projected: %#v",m.modalItems)
 }
}
func TestToolUsesConsoleProtocolField(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"tool.started","tool_name":"bash","tool_call_id":"t-1"}`))
 if len(m.transcript)!=1||!strings.Contains(m.transcript[0],"bash") {
  t.Fatalf("tool renderer dropped wire name: %v",m.transcript)
 }
}
