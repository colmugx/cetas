package main

import (
 "encoding/json"
 "context"
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
 if !m.running || m.streaming!="hello world" {t.Fatalf("streaming state: %#v",m)}
 m.applyEvent(event(`{"type":"turn.completed","text":"hello world"}`))
 if m.running || len(m.transcript)!=1 || m.transcript[0]!="hello world" {t.Fatalf("settled transcript: %#v",m.transcript)}
 if len(m.streaming)!=0 {t.Fatal("live text not cleared")}
}
func TestFailedTurnDoesNotKeepStreamingState(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"turn.started"}`))
 m.applyEvent(event(`{"type":"assistant.text_delta","delta":"partial"}`))
 m.applyEvent(event(`{"type":"turn.failed","message":"cancelled"}`))
 if m.running || len(m.streaming)!=0 || !strings.Contains(strings.Join(m.transcript,"\n"),"cancelled") {t.Fatalf("failed state: %#v",m.transcript)}
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

func TestModalRequestFIFOAndCancellation(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"ui.request","session_id":"s-1","request_id":"u-1","kind":"confirm","prompt":"approve?"}`))
 m.applyEvent(event(`{"type":"ui.request","session_id":"s-1","request_id":"u-2","kind":"input","prompt":"credential","default":"abc"}`))
 if m.modalRequestID!="u-1"||len(m.pendingUI)!=1 {t.Fatalf("lost queued request: %#v",m)}
 _=m.answerModal(map[string]any{"cancelled":true})
 if m.modalRequestID!="u-2"||m.modal!="input"||string(m.modalBuffer)!="abc" {t.Fatalf("did not activate next request: %#v",m)}
}
func TestIgnoreOtherSessionEvents(t *testing.T) {
 m:=newModel();m.session="s-1"
 m.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-2","delta":"foreign"}`))
 if m.streaming!=""||m.session!="s-1" {t.Fatalf("cross-session event entered UI: %#v",m)}
 m.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-1","delta":"ours"}`))
 if m.streaming!="ours" {t.Fatalf("own session event dropped: %#v",m)}
}
func TestStreamingModelCopyIsSafe(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-1","delta":"first"}`))
 copied:=m
 copied.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-1","delta":"second"}`))
 if m.streaming!="first"||copied.streaming!="firstsecond" {t.Fatalf("copy lost immutable streaming state: %q %q",m.streaming,copied.streaming)}
}
func TestTranscriptReplayedFromConsole(t *testing.T) {
 m:=newModel();m.session="s-1"
 out,_:=m.Update(commandResult{name:"session_transcript",payload:json.RawMessage(`{"items":[{"kind":"user","text":"你好"},{"kind":"assistant","text":"hello"},{"kind":"tool","name":"bash"}]}`)})
 state:=out.(model)
 if len(state.transcript)!=3||state.transcript[0]!="> 你好"||!strings.Contains(state.transcript[2],"bash") {t.Fatalf("replay: %#v",state.transcript)}
}

type testHost struct{}
func (*testHost) Request(context.Context,string,any)(json.RawMessage,error){return json.RawMessage("{}"),nil}
func (*testHost) Events() <-chan harness.Event {return nil}
func (*testHost) Errors() <-chan error {return nil}
func (*testHost) Close(context.Context) error {return nil}

func TestFollowupWaitsUntilMoonBitIdleSnapshot(t *testing.T) {
 m:=newModel();m.host=&testHost{};m.session="s-1";m.running=true;m.followups=[]string{"next"}
 out,_:=m.Update(eventBatchResult{events:[]harness.Event{event(`{"type":"turn.completed","session_id":"s-1","text":"ok"}`)}})
 mid:=out.(model)
 if len(mid.followups)!=1 {t.Fatal("followup started before idle snapshot")}
 out,_=mid.Update(eventBatchResult{events:[]harness.Event{event(`{"type":"session.snapshot","session_id":"s-1","busy":false}`)}})
 last:=out.(model)
 if len(last.followups)!=0||!last.running {t.Fatalf("followup not dispatched on idle: %#v",last)}
}
func TestToolCompletionMatchesCallID(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"tool.started","session_id":"s","tool_call_id":"tc-1","tool_name":"bash"}`))
 m.applyEvent(event(`{"type":"tool.completed","session_id":"s","tool_call_id":"tc-1","tool_name":"bash","is_error":false}`))
 if len(m.transcript)!=1||!strings.Contains(m.transcript[0],"✓") {t.Fatalf("tool completion not adopted: %#v",m.transcript)}
}
func TestExtensionStatusRender(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"ui.render","slot":"Status","text":"working: 25%"}`))
 if m.status!="working: 25%" {t.Fatalf("status UI dropped: %q",m.status)}
}
func TestFinalMarkdownIsCached(t *testing.T) {
 m:=newModel();m.appendAssistant("**bold** and `code`")
 m.refreshTranscript()
 if got:=m.markdownCache[0];!strings.Contains(got,"bold")||!strings.Contains(got,"code") {t.Fatalf("markdown not rendered: %q",got)}
}
