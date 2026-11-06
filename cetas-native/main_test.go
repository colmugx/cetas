package main

import (
 "encoding/json"
 "context"
 "strings"
 "testing"

 "github.com/colmugx/cetas/cetas-native/harness"
 tea "charm.land/bubbletea/v2"
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

func TestProtocolErrorDoesNotSilentlySucceed(t *testing.T) {
 m:=newModel();m.running=true
 next,_:=m.Update(commandResult{name:"turn_start",payload:json.RawMessage(`{"error":"session is busy"}`)})
 state:=next.(model)
 if state.running || !strings.Contains(state.err,"session is busy") {t.Fatalf("protocol error lost: %#v",state)}
}
func TestStartupLoadsPersistedTranscript(t *testing.T) {
 m:=newModel();m.host=&testHost{}
 next,cmd:=m.Update(commandResult{name:"runtime_state",payload:json.RawMessage(`{"session_id":"s-1","status":"ready"}`)})
 state:=next.(model)
 if state.session!="s-1"||cmd==nil {t.Fatalf("startup failed to request replay: %#v",state)}
}

func TestSlashTabOpensPickerAndInsertKeepsDraft(t *testing.T) {
 m:=newModel()
 m.textarea.SetValue("/mo")
 next,_:=m.Update(tea.KeyPressMsg{Code:tea.KeyTab})
 state:=next.(model)
 if state.modal!="slash"||len(state.modalValues)==0||state.modalValues[0]!="/model" {
  t.Fatalf("slash completion picker: %#v",state.modalValues)
 }
 next,cmd:=state.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 state=next.(model)
 if cmd!=nil||state.modal!=""||state.textarea.Value()!="/model" {
  t.Fatalf("completion must only edit the prompt: %#v",state)
 }
}

func TestUiDismissRetiresOnlyMatchingPendingPrompt(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"approval"}`))
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-2","kind":"input","prompt":"second"}`))
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-3","kind":"select","prompt":"third","options":["a","b"]}`))
 m.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-2"}`))
 if m.modalRequestID!="u-1"||len(m.pendingUI)!=1||m.pendingUI[0].id!="u-3" {
  t.Fatalf("queued dismiss lost active/following prompts: active=%q queued=%#v",m.modalRequestID,m.pendingUI)
 }
 m.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-1"}`))
 if m.modalRequestID!="u-3"||m.modal!="select"||len(m.pendingUI)!=0 {
  t.Fatalf("active dismiss did not advance FIFO: active=%q modal=%q queued=%#v",m.modalRequestID,m.modal,m.pendingUI)
 }
}

func TestUiDismissAfterReplyCannotCloseNextPrompt(t *testing.T) {
 m:=newModel()
 m.host=&testHost{}
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"approval"}`))
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-2","kind":"input","prompt":"secret"}`))
 next,cmd:=m.Update(tea.KeyPressMsg{Code:tea.KeyEsc})
 state:=next.(model)
 if cmd==nil||state.modalRequestID!="u-2" {
  t.Fatalf("escape did not cancel first prompt and advance: %#v",state)
 }
 state.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-1"}`))
 state.applyEvent(event(`{"type":"ui.dismiss","request_id":"unknown"}`))
 state.applyEvent(event(`{"type":"ui.dismiss"}`))
 if state.modalRequestID!="u-2"||state.modal!="input" {
  t.Fatalf("late/unknown dismissal closed current prompt: %#v",state)
 }
 state.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-2"}`))
 if state.modalRequestID!=""||state.modal!=""||len(state.pendingUI)!=0 {
  t.Fatalf("dismiss did not clear last prompt: %#v",state)
 }
}

func TestUiDismissDoesNotCloseUnrelatedPicker(t *testing.T) {
 m:=newModel()
 m.modal="slash";m.modalValues=[]string{"/help"}
 m.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-1"}`))
 if m.modal!="slash"||len(m.modalValues)!=1 {
  t.Fatalf("unrelated dismissal closed local picker: %#v",m)
 }
 m.applyEvent(event(`{"type":"ui.request","kind":"confirm","prompt":"missing id"}`))
 if m.modal!="slash"||m.modalRequestID!=""||m.err=="" {
  t.Fatalf("malformed request corrupted selection: %#v",m)
 }
}

func TestSecretUiPromptNeverRendersCredential(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-secret","kind":"secret","prompt":"API Key","default":"LEAKED-DEFAULT"}`))
 if m.modal!="secret"||len(m.modalBuffer)!=0 {
  t.Fatalf("secret prompt must never prefill credentials: modal=%q buffer=%d",m.modal,len(m.modalBuffer))
 }
 m.modalBuffer=[]rune("sensitive-credential-xyz")
 view:=m.View()
 if strings.Contains(view.Content,"sensitive-credential-xyz")||strings.Contains(view.Content,"LEAKED-DEFAULT") {
  t.Fatal("secret leaked through the terminal view")
 }
 if !strings.Contains(view.Content,"••••") {
  t.Fatal("secret input did not show masked feedback")
 }
}

func TestSecretReplyIsCorrelatedAndCleared(t *testing.T) {
 m:=newModel()
 m.host=&testHost{}
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-secret","kind":"secret","prompt":"API Key"}`))
 m.modalBuffer=[]rune("private-key")
 next,cmd:=m.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 state:=next.(model)
 if cmd==nil||state.modalRequestID!=""||state.modal!=""||len(state.modalBuffer)!=0 {
  t.Fatalf("secret reply left credential in active modal: %#v",state.modal)
 }
 response:=cmd()
 if result,ok:=response.(commandResult);!ok||result.name!="ui_response" {
  t.Fatalf("missing correlated UiPort response: %#v",response)
 }
}

func TestLoginCompletionDoesNotEchoProviderError(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"auth.login","provider":"example","result":{"type":"error","error":"bad credential sensitive-credential-xyz"}}`))
 if m.status!="authentication failed"||!strings.Contains(m.err,"example") {
  t.Fatalf("login failure was lost: status=%q err=%q",m.status,m.err)
 }
 if strings.Contains(m.View().Content,"sensitive-credential-xyz") {
  t.Fatal("provider error text leaked potentially sensitive input")
 }
 m.applyEvent(event(`{"type":"auth.login","provider":"example","result":{"type":"success","feedback":"logged in"}}`))
 if !strings.Contains(m.status,"signed in") {
  t.Fatalf("login completion not rendered: %q",m.status)
 }
}

func TestSkillsBrowserIsReadOnly(t *testing.T) {
 m:=newModel()
 m.host=&testHost{}
 m.textarea.SetValue("unchanged draft")
 cmd:=m.command("/skills")
 if cmd==nil {t.Fatal("missing skills browse command")}
 result,ok:=cmd().(commandResult)
 if !ok||result.name!="skills_browse" {t.Fatalf("browse response must preserve intent: %#v",result)}
 next,_:=m.Update(commandResult{name:"skills_browse",payload:json.RawMessage(`{"skills":[{"name":"example","description":"Example skill"}]}`)})
 state:=next.(model)
 if state.modal!="skills_browse"||len(state.modalValues)!=1||state.modalValues[0]!="example" {
  t.Fatalf("browse picker did not open: %#v",state)
 }
 next,cmd=state.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 state=next.(model)
 if cmd!=nil||state.modal!=""||state.textarea.Value()!="unchanged draft" {
  t.Fatalf("browse selected a skill instead of closing: %#v",state)
 }
}

func TestSkillCompletionDoesNotAcceptStaleResponse(t *testing.T) {
 m:=newModel()
 m.completionToken="$exa"
 m.textarea.SetValue("please use $different")
 next,_:=m.Update(commandResult{name:"skills",payload:json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
 state:=next.(model)
 if state.modal!=""||state.textarea.Value()!="please use $different" {
  t.Fatalf("stale completion overwrote changed draft: %#v",state)
 }
 m.textarea.SetValue("please use $exa")
 m.completionPrefix="please use "
 next,_=m.Update(commandResult{name:"skills",payload:json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
 state=next.(model)
 if state.modal!="skills"||len(state.modalValues)!=1 {
  t.Fatalf("current completion did not open: %#v",state.modalValues)
 }
 next,_=state.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 state=next.(model)
 if state.textarea.Value()!="please use $example " {
  t.Fatalf("completion did not insert skill: %q",state.textarea.Value())
 }
}

func TestSkillsBrowserReplyDoesNotReplaceSkillCompletion(t *testing.T) {
 m:=newModel()
 m.textarea.SetValue("$exa")
 m.completionToken="$exa"
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"approval"}`))
 next,_:=m.Update(commandResult{name:"skills_browse",payload:json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
 state:=next.(model)
 if state.modalRequestID!="u-1" {
  t.Fatalf("async browse response must not replace active approval: %#v",state)
 }
}

func TestStructuredAuthResultDoesNotBreakEventProjection(t *testing.T) {
 m:=newModel()
 m.applyEvent(event(`{"type":"auth.login","session_id":"s1","provider":"openai","result":{"type":"success","structured":{"provider":"openai"},"feedback":"ok"}}`))
 if m.session!="s1"||m.status!="signed in to openai" {
  t.Fatalf("structured EventHub result was discarded: session=%q status=%q",m.session,m.status)
 }
 // Tool output is still a text wire field, including content that resembles
 // JSON; changing auth result decoding must not break tool completion.
 m.showTools=true
 m.applyEvent(event(`{"type":"tool.started","session_id":"s1","tool_call_id":"t1","tool_name":"read"}`))
 m.applyEvent(event(`{"type":"tool.completed","session_id":"s1","tool_call_id":"t1","tool_name":"read","result":"plain result"}`))
 if !strings.Contains(strings.Join(m.transcript,"\n"),"plain result") {
  t.Fatalf("string tool output was lost: %#v",m.transcript)
 }
 m.applyEvent(event(`{"type":"tool.started","session_id":"s1","tool_call_id":"t2","tool_name":"read"}`))
 m.applyEvent(event(`{"type":"tool.completed","session_id":"s1","tool_call_id":"t2","tool_name":"read","result":{"kind":"json"}}`))
 if !strings.Contains(strings.Join(m.transcript,"\n"),`"kind":"json"`) {
  t.Fatalf("structured tool result was lost: %#v",m.transcript)
 }
}

func TestLocalCompletionPickerWorksBeforeHostBoot(t *testing.T) {
 m:=newModel()
 m.textarea.SetValue("use $exa")
 m.completionPrefix="use "
 m.completionToken="$exa"
 next,_:=m.Update(commandResult{name:"skills",payload:json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
 state:=next.(model)
 if state.modal!="skills"||state.host!=nil {t.Fatalf("picker not available without host: %#v",state.modal)}
 next,cmd:=state.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 state=next.(model)
 if cmd!=nil||state.textarea.Value()!="use $example " {
  t.Fatalf("local completion must insert without dispatch: %q",state.textarea.Value())
 }
}

func TestOAuthEscapeCancelsByAuthIDWithoutAbortingTurn(t *testing.T) {
 m:=newModel()
 m.host=&testHost{}
 next,_:=m.Update(commandResult{name:"login",payload:json.RawMessage(`{"status":"started","auth_id":"auth-5","provider":"example"}`)})
 state:=next.(model)
 if state.authID!="auth-5" {t.Fatalf("lost login id: %q",state.authID)}
 next,cmd:=state.Update(tea.KeyPressMsg{Code:tea.KeyEsc})
 state=next.(model)
 if cmd==nil||state.status!="cancelling authentication" {
  t.Fatalf("Escape did not initiate OAuth cancellation: status=%q",state.status)
 }
 result,ok:=cmd().(commandResult)
 if !ok||result.name!="login_cancel" {t.Fatalf("wrong cancellation command: %#v",result)}
 state.applyEvent(event(`{"type":"auth.cancelled","auth_id":"auth-other"}`))
 if state.authID!="auth-5" {t.Fatal("foreign cancellation cleared active login")}
 state.applyEvent(event(`{"type":"auth.cancelled","auth_id":"auth-5"}`))
 if state.authID!=""||state.status!="authentication cancelled" {
  t.Fatalf("matched login cancellation did not settle: id=%q status=%q",state.authID,state.status)
 }
}

func TestCancelledOAuthResultCannotOverwriteNewLogin(t *testing.T) {
 m:=newModel()
 m.session="s-1"
 m.authID="auth-2"
 m.status="authenticating second"
 m.applyEvent(event(`{"type":"auth.login","session_id":"s-1","auth_id":"auth-1","provider":"old","result":{"type":"success","feedback":"old result"}}`))
 if m.authID!="auth-2"||m.status!="authenticating second" {
  t.Fatalf("stale login result replaced active login: id=%q status=%q",m.authID,m.status)
 }
 m.applyEvent(event(`{"type":"auth.login","session_id":"s-1","auth_id":"auth-2","provider":"new","result":{"type":"success","feedback":"done"}}`))
 if m.authID!=""||m.status!="signed in to new" {
  t.Fatalf("active login did not finish: id=%q status=%q",m.authID,m.status)
 }
 m.applyEvent(event(`{"type":"auth.cancelled","session_id":"s-1","auth_id":"auth-1"}`))
 if m.status!="signed in to new" {t.Fatal("late cancellation regressed completed login")}
}

func TestLoginCancelNotFoundDoesNotStallUI(t *testing.T) {
 m:=newModel()
 m.authID="auth-3"
 next,_:=m.Update(commandResult{name:"login_cancel",payload:json.RawMessage(`{"cancelled":false,"auth_id":"auth-3"}`)})
 state:=next.(model)
 if state.authID!=""||state.status!="authentication already settled" {
  t.Fatalf("missing login task must reset UI: id=%q status=%q",state.authID,state.status)
 }
}
