package tui

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/colmugx/cetas/cetas-native/internal/wire"
)

func event(raw string) wire.Event {
	return wire.Event{Raw: json.RawMessage(raw)}
}
func TestStreamingTurnSettlesOnce(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"turn.started","session_id":"s-1"}`))
	m.applyEvent(event(`{"type":"assistant.text_delta","delta":"hello "}`))
	m.applyEvent(event(`{"type":"assistant.text_delta","delta":"world"}`))
	if !m.running || m.streaming != "hello world" {
		t.Fatalf("streaming state: %#v", m)
	}
	m.applyEvent(event(`{"type":"turn.completed","text":"hello world"}`))
	if m.running || len(m.transcript) != 1 || m.transcript[0] != "hello world" {
		t.Fatalf("settled transcript: %#v", m.transcript)
	}
	if len(m.streaming) != 0 {
		t.Fatal("live text not cleared")
	}
}
func TestEditorResizesForSmallTerminal(t *testing.T) {
	m := newModel()
	m.width = 18
	m.height = 6
	m.resize()
	// JS parity uses actual terminal columns, not the former 20-column minimum.
	if m.viewport.Height() < 1 || m.viewport.Width() != 18 {
		t.Fatalf("bad dimensions: %d x %d", m.viewport.Width(), m.viewport.Height())
	}
	for _, line := range strings.Split(m.View().Content, "\n") {
		if lipgloss.Width(line) > 18 {
			t.Fatalf("small terminal overflow: %q", line)
		}
	}
}

func TestModalRequestFIFOAndCancellation(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"ui.request","session_id":"s-1","request_id":"u-1","kind":"confirm","prompt":"approve?"}`))
	m.applyEvent(event(`{"type":"ui.request","session_id":"s-1","request_id":"u-2","kind":"input","prompt":"credential","default":"abc"}`))
	if m.modalRequestID != "u-1" || len(m.pendingUI) != 1 {
		t.Fatalf("lost queued request: %#v", m)
	}
	_ = m.answerModal(map[string]any{"cancelled": true})
	if m.modalRequestID != "u-2" || m.modal != "input" || string(m.modalBuffer) != "abc" {
		t.Fatalf("did not activate next request: %#v", m)
	}
}
func TestIgnoreOtherSessionEvents(t *testing.T) {
	m := newModel()
	m.session = "s-1"
	m.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-2","delta":"foreign"}`))
	if m.streaming != "" || m.session != "s-1" {
		t.Fatalf("cross-session event entered UI: %#v", m)
	}
	m.applyEvent(event(`{"type":"assistant.text_delta","session_id":"s-1","delta":"ours"}`))
	if m.streaming != "ours" {
		t.Fatalf("own session event dropped: %#v", m)
	}
}

type testHost struct{}

func (*testHost) Request(context.Context, string, any) (json.RawMessage, error) {
	return json.RawMessage("{}"), nil
}
func (*testHost) Events() <-chan wire.Event   { return nil }
func (*testHost) Errors() <-chan error        { return nil }
func (*testHost) Close(context.Context) error { return nil }

func TestFollowupWaitsUntilMoonBitIdleSnapshot(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.session = "s-1"
	m.running = true
	m.followups = []string{"next"}
	out, _ := m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"turn.completed","session_id":"s-1","text":"ok"}`)}})
	mid := out.(model)
	if len(mid.followups) != 1 {
		t.Fatal("followup started before idle snapshot")
	}
	out, _ = mid.Update(eventBatchResult{events: []wire.Event{event(`{"type":"session.snapshot","session_id":"s-1","busy":false}`)}})
	last := out.(model)
	if len(last.followups) != 0 || !last.running {
		t.Fatalf("followup not dispatched on idle: %#v", last)
	}
}
func TestToolCompletionMatchesCallID(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"tool.started","session_id":"s","tool_call_id":"tc-1","tool_name":"bash"}`))
	m.applyEvent(event(`{"type":"tool.completed","session_id":"s","tool_call_id":"tc-1","tool_name":"bash","is_error":false}`))
	if len(m.transcript) != 1 || !strings.Contains(m.transcript[0], "✓") {
		t.Fatalf("tool completion not adopted: %#v", m.transcript)
	}
}

func TestHostileToolResultIsSanitizedAtIngest(t *testing.T) {
	m := newModel()
	m.showTools = true
	// A hostile tool body carrying OSC 8 link spoofing, a clipboard write and
	// a screen clear, beside a legitimate SGR color: everything but the SGR
	// must die before the text reaches any transcript surface.
	body, err := json.Marshal("\x1b]8;;http://evil.example\x1b\\click\x1b]8;;\x1b\\ \x1b]52;c;AAAA\x07 \x1b[2J \x1b[31mred\x1b[0m")
	if err != nil {
		t.Fatal(err)
	}
	m.applyEvent(event(`{"type":"tool.started","session_id":"s","tool_call_id":"tc-x","tool_name":"bash"}`))
	m.applyEvent(event(`{"type":"tool.completed","session_id":"s","tool_call_id":"tc-x","tool_name":"bash","is_error":false,"result":` + string(body) + `}`))
	joined := strings.Join(m.transcript, "\n")
	if strings.Contains(joined, "evil.example") || strings.Contains(joined, "\x1b]") || strings.Contains(joined, "\x1b[2J") {
		t.Fatalf("unsafe tool result reached the transcript: %q", joined)
	}
	if !strings.Contains(joined, "\x1b[31mred\x1b[0m") {
		t.Fatalf("legitimate SGR color was stripped: %q", joined)
	}
}

func TestProtocolErrorDoesNotSilentlySucceed(t *testing.T) {
	m := newModel()
	m.running = true
	next, _ := m.Update(commandResult{name: "turn_start", payload: json.RawMessage(`{"error":"session is busy"}`)})
	state := next.(model)
	if state.running || !strings.Contains(state.err, "session is busy") {
		t.Fatalf("protocol error lost: %#v", state)
	}
}

func TestSlashTabOpensPickerAndInsertKeepsDraft(t *testing.T) {
	m := newModel()
	m.textarea.SetValue("/mo")
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	state := next.(model)
	// Bottom-up stacking: the best match ("/model" for "/mo") is the last
	// row and the cursor starts on it.
	if state.modal != "slash" || len(state.modalValues) == 0 || state.modalValues[state.modalIndex] != "/model" {
		t.Fatalf("slash completion picker: %#v at %d", state.modalValues, state.modalIndex)
	}
	if state.modalIndex != len(state.modalValues)-1 {
		t.Fatalf("cursor starts at %d, want the bottom row", state.modalIndex)
	}
	next, cmd := state.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	state = next.(model)
	if cmd != nil || state.modal != "" || state.textarea.Value() != "/model" {
		t.Fatalf("Tab completion must only edit the prompt: %#v", state)
	}
}

func TestUiDismissAfterReplyCannotCloseNextPrompt(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"approval"}`))
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-2","kind":"input","prompt":"secret"}`))
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	state := next.(model)
	if cmd == nil || state.modalRequestID != "u-2" {
		t.Fatalf("escape did not cancel first prompt and advance: %#v", state)
	}
	state.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-1"}`))
	state.applyEvent(event(`{"type":"ui.dismiss","request_id":"unknown"}`))
	state.applyEvent(event(`{"type":"ui.dismiss"}`))
	if state.modalRequestID != "u-2" || state.modal != "input" {
		t.Fatalf("late/unknown dismissal closed current prompt: %#v", state)
	}
	state.applyEvent(event(`{"type":"ui.dismiss","request_id":"u-2"}`))
	if state.modalRequestID != "" || state.modal != "" || len(state.pendingUI) != 0 {
		t.Fatalf("dismiss did not clear last prompt: %#v", state)
	}
}

func TestSecretUiPromptNeverRendersCredential(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-secret","kind":"secret","prompt":"API Key","default":"LEAKED-DEFAULT"}`))
	if m.modal != "secret" || len(m.modalBuffer) != 0 {
		t.Fatalf("secret prompt must never prefill credentials: modal=%q buffer=%d", m.modal, len(m.modalBuffer))
	}
	m.modalBuffer = []rune("sensitive-credential-xyz")
	view := m.View()
	if strings.Contains(view.Content, "sensitive-credential-xyz") || strings.Contains(view.Content, "LEAKED-DEFAULT") {
		t.Fatal("secret leaked through the terminal view")
	}
	if !strings.Contains(view.Content, "••••") {
		t.Fatal("secret input did not show masked feedback")
	}
}

func TestSecretReplyIsCorrelatedAndCleared(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-secret","kind":"secret","prompt":"API Key"}`))
	m.modalBuffer = []rune("private-key")
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	state := next.(model)
	if cmd == nil || state.modalRequestID != "" || state.modal != "" || len(state.modalBuffer) != 0 {
		t.Fatalf("secret reply left credential in active modal: %#v", state.modal)
	}
	var response commandResult
	for _, msg := range cmdMsgs(t, cmd) {
		if result, ok := msg.(commandResult); ok {
			response = result
		}
	}
	if response.name != "ui_response" {
		t.Fatalf("missing correlated UiPort response: %#v", response)
	}
}

func TestLoginCompletionDoesNotEchoProviderError(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"auth.login","provider":"example","result":{"type":"error","error":"bad credential sensitive-credential-xyz"}}`))
	if m.status != "authentication failed" || !strings.Contains(m.err, "example") {
		t.Fatalf("login failure was lost: status=%q err=%q", m.status, m.err)
	}
	if strings.Contains(m.View().Content, "sensitive-credential-xyz") {
		t.Fatal("provider error text leaked potentially sensitive input")
	}
	m.applyEvent(event(`{"type":"auth.login","provider":"example","result":{"type":"success","feedback":"logged in"}}`))
	if !strings.Contains(m.status, "signed in") {
		t.Fatalf("login completion not rendered: %q", m.status)
	}
}

func TestSkillsBrowserIsReadOnly(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.textarea.SetValue("unchanged draft")
	cmd := m.command("/skills")
	if cmd == nil {
		t.Fatal("missing skills browse command")
	}
	result, ok := cmd().(commandResult)
	if !ok || result.name != "skills_browse" {
		t.Fatalf("browse response must preserve intent: %#v", result)
	}
	next, _ := m.Update(commandResult{name: "skills_browse", payload: json.RawMessage(`{"skills":[{"name":"example","description":"Example skill"}]}`)})
	state := next.(model)
	if state.modal != "skills_browse" || len(state.modalValues) != 1 || state.modalValues[0] != "example" {
		t.Fatalf("browse picker did not open: %#v", state)
	}
	next, cmd = state.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	state = next.(model)
	if cmd != nil || state.modal != "" || state.textarea.Value() != "unchanged draft" {
		t.Fatalf("browse selected a skill instead of closing: %#v", state)
	}
}

func TestSkillCompletionDoesNotAcceptStaleResponse(t *testing.T) {
	m := newModel()
	m.completionToken = "$exa"
	m.textarea.SetValue("please use $different")
	next, _ := m.Update(commandResult{name: "skills", payload: json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
	state := next.(model)
	if state.modal != "" || state.textarea.Value() != "please use $different" {
		t.Fatalf("stale completion overwrote changed draft: %#v", state)
	}
	m.textarea.SetValue("please use $exa")
	m.completionPrefix = "please use "
	next, _ = m.Update(commandResult{name: "skills", payload: json.RawMessage(`{"skills":[{"name":"example","description":"Example"}]}`)})
	state = next.(model)
	if state.modal != "skills" || len(state.modalValues) != 1 {
		t.Fatalf("current completion did not open: %#v", state.modalValues)
	}
	next, _ = state.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	state = next.(model)
	if state.textarea.Value() != "please use $example " {
		t.Fatalf("completion did not insert skill: %q", state.textarea.Value())
	}
}

func TestStructuredAuthResultDoesNotBreakEventProjection(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"auth.login","session_id":"s1","provider":"openai","result":{"type":"success","structured":{"provider":"openai"},"feedback":"ok"}}`))
	if m.session != "s1" || m.status != "signed in to openai" {
		t.Fatalf("structured EventHub result was discarded: session=%q status=%q", m.session, m.status)
	}
	// Tool output is still a text wire field, including content that resembles
	// JSON; changing auth result decoding must not break tool completion.
	m.showTools = true
	m.applyEvent(event(`{"type":"tool.started","session_id":"s1","tool_call_id":"t1","tool_name":"read"}`))
	m.applyEvent(event(`{"type":"tool.completed","session_id":"s1","tool_call_id":"t1","tool_name":"read","result":"plain result"}`))
	if !strings.Contains(strings.Join(m.transcript, "\n"), "plain result") {
		t.Fatalf("string tool output was lost: %#v", m.transcript)
	}
	m.applyEvent(event(`{"type":"tool.started","session_id":"s1","tool_call_id":"t2","tool_name":"read"}`))
	m.applyEvent(event(`{"type":"tool.completed","session_id":"s1","tool_call_id":"t2","tool_name":"read","result":{"kind":"json"}}`))
	if !strings.Contains(strings.Join(m.transcript, "\n"), `"kind":"json"`) {
		t.Fatalf("structured tool result was lost: %#v", m.transcript)
	}
}

func TestOAuthEscapeCancelsByAuthIDWithoutAbortingTurn(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	next, _ := m.Update(commandResult{name: "login", payload: json.RawMessage(`{"status":"started","auth_id":"auth-5","provider":"example"}`)})
	state := next.(model)
	if state.authID != "auth-5" {
		t.Fatalf("lost login id: %q", state.authID)
	}
	next, cmd := state.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	state = next.(model)
	if cmd == nil || state.status != "cancelling authentication" {
		t.Fatalf("Escape did not initiate OAuth cancellation: status=%q", state.status)
	}
	result, ok := cmd().(commandResult)
	if !ok || result.name != "login_cancel" {
		t.Fatalf("wrong cancellation command: %#v", result)
	}
	state.applyEvent(event(`{"type":"auth.cancelled","auth_id":"auth-other"}`))
	if state.authID != "auth-5" {
		t.Fatal("foreign cancellation cleared active login")
	}
	state.applyEvent(event(`{"type":"auth.cancelled","auth_id":"auth-5"}`))
	if state.authID != "" || state.status != "authentication cancelled" {
		t.Fatalf("matched login cancellation did not settle: id=%q status=%q", state.authID, state.status)
	}
}

func TestCancelledOAuthResultCannotOverwriteNewLogin(t *testing.T) {
	m := newModel()
	m.session = "s-1"
	m.authID = "auth-2"
	m.status = "authenticating second"
	m.applyEvent(event(`{"type":"auth.login","session_id":"s-1","auth_id":"auth-1","provider":"old","result":{"type":"success","feedback":"old result"}}`))
	if m.authID != "auth-2" || m.status != "authenticating second" {
		t.Fatalf("stale login result replaced active login: id=%q status=%q", m.authID, m.status)
	}
	m.applyEvent(event(`{"type":"auth.login","session_id":"s-1","auth_id":"auth-2","provider":"new","result":{"type":"success","feedback":"done"}}`))
	if m.authID != "" || m.status != "signed in to new" {
		t.Fatalf("active login did not finish: id=%q status=%q", m.authID, m.status)
	}
	m.applyEvent(event(`{"type":"auth.cancelled","session_id":"s-1","auth_id":"auth-1"}`))
	if m.status != "signed in to new" {
		t.Fatal("late cancellation regressed completed login")
	}
}

func TestLoginCancelNotFoundDoesNotStallUI(t *testing.T) {
	m := newModel()
	m.authID = "auth-3"
	next, _ := m.Update(commandResult{name: "login_cancel", payload: json.RawMessage(`{"cancelled":false,"auth_id":"auth-3"}`)})
	state := next.(model)
	if state.authID != "" || state.status != "authentication already settled" {
		t.Fatalf("missing login task must reset UI: id=%q status=%q", state.authID, state.status)
	}
}

func TestOAuthCompletionSurvivesSessionSwitch(t *testing.T) {
	m := newModel()
	m.session = "session-new"
	m.authID = "auth-7"
	m.applyEvent(event(`{"type":"auth.login","session_id":"session-old","auth_id":"auth-7","provider":"example","result":{"type":"success","feedback":"done"}}`))
	if m.session != "session-new" || m.authID != "" || m.status != "signed in to example" {
		t.Fatalf("global OAuth result lost when session changed: session=%q auth=%q status=%q", m.session, m.authID, m.status)
	}
	m.authID = "auth-8"
	m.applyEvent(event(`{"type":"auth.cancelled","session_id":"session-old","auth_id":"auth-8"}`))
	if m.authID != "" || m.status != "authentication cancelled" {
		t.Fatalf("global auth cancellation lost after session switch: %q %q", m.authID, m.status)
	}
}
