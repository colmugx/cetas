package tui

import (
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
	"time"
)

func TestInlineQuestionUsesWireDefaultAndHasMaskedCursor(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 24
	m.resize()
	m.applyEvent(event(`{"type":"ui.request","request_id":"pick","kind":"select","prompt":"Pick","options":["A","B","C"],"default":2}`))
	if m.modalIndex != 2 {
		t.Fatal("wire default selection ignored")
	}
	m.dismissUI("pick")
	m.applyEvent(event(`{"type":"ui.request","request_id":"secret","kind":"secret","prompt":"API key"}`))
	m.modalBuffer = []rune("秘密")
	view := m.View()
	if view.Cursor == nil {
		t.Fatal("secret input has no visible cursor")
	}
	lines := strings.Split(ansi.Strip(view.Content), "\n")
	if view.Cursor.Y >= len(lines) || !strings.HasPrefix(strings.TrimSpace(lines[view.Cursor.Y]), "> ••") {
		t.Fatalf("input cursor is on wrong region: %#v", view.Cursor)
	}
	if strings.Contains(view.Content, "秘密") {
		t.Fatal("secret leaked")
	}
}

func TestStreamedToolArgumentsAdoptSingleAuthoritativeCall(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 24
	m.resize()
	m.applyEvent(event(`{"type":"tool.args_delta","index":0,"id":"call1","name":"read","delta":"{\"path\":"}`))
	m.applyEvent(event(`{"type":"tool.args_delta","index":0,"delta":"\"hello.go\"}"}`))
	if m.err != "" {
		t.Fatal(m.err)
	}
	m.applyEvent(event(`{"type":"tool.started","phase":"pending","tool_call_id":"call1","tool_name":"read","arguments":{"path":"hello.go"}}`))
	m.applyEvent(event(`{"type":"tool.completed","phase":"rejected","tool_call_id":"call1","tool_name":"read","result":"Denied","is_error":true}`))
	m.applyEvent(event(`{"type":"tool.started_run","phase":"started","tool_call_id":"call1","tool_name":"read"}`))
	m.reflow() // Mirror Update after directly injecting a reducer event.
	view := ansi.Strip(m.View().Content)
	if len(m.transcript) != 1 || strings.Count(view, "● read") != 1 || !strings.Contains(view, "hello.go") {
		t.Fatalf("streamed args duplicated or lost: %s", view)
	}
	if m.blocks[0].State != "rejected" {
		t.Fatalf("late start revived terminal node: %q", m.blocks[0].State)
	}
}

func TestInlineAskKeepsConversationAndEditorVisible(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 30
	m.resize()
	m.appendAssistant("CONVERSATION_ANCHOR")
	m.textarea.SetValue("my unfinished draft")
	m.refreshTranscript()
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"Approve changes?"}`))
	view := ansi.Strip(m.View().Content)
	for _, text := range []string{"CONVERSATION_ANCHOR", "my unfinished draft", "Approve changes?"} {
		if !strings.Contains(view, text) {
			t.Fatalf("inline ask hid %q: %s", text, view)
		}
	}
}

func TestLiveMarkdownUsesSamePresentationAsFinalMessage(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 24
	m.resize()
	m.applyEvent(event(`{"type":"assistant.text_delta","delta":"**bold** and ` + "`code`" + `"}`))
	m.refreshTranscript()
	live := ansi.Strip(m.viewport.View())
	if strings.Contains(live, "**") {
		t.Fatalf("live Markdown is raw: %s", live)
	}
	m.applyEvent(event(`{"type":"turn.completed"}`))
	m.refreshTranscript()
	if live != ansi.Strip(m.viewport.View()) {
		t.Fatalf("stream completion changed presentation\nlive:%s\nfinal:%s", live, ansi.Strip(m.viewport.View()))
	}
}

func TestReplayedToolPreservesLiveArgumentsAndPresentation(t *testing.T) {
	live := newModel()
	live.width = 80
	live.height = 24
	live.resize()
	live.applyEvent(event(`{"type":"tool.started","tool_call_id":"call-1","tool_name":"read","arguments":{"path":"hello.go"}}`))
	live.applyEvent(event(`{"type":"tool.completed","tool_call_id":"call-1","tool_name":"read","result":"first\nsecond"}`))
	live.reflow()
	replay := newModel()
	replay.width = 80
	replay.height = 24
	replay.resize()
	next, _ := replay.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[{"kind":"tool","callId":"call-1","name":"read","args":{"path":"hello.go"},"status":"done","result":"first\nsecond"}]}`)})
	replay = next.(model)
	if ansi.Strip(live.View().Content) != ansi.Strip(replay.View().Content) {
		t.Fatalf("replay differs from live tool\nlive: %s\nreplay: %s", ansi.Strip(live.View().Content), ansi.Strip(replay.View().Content))
	}
}

func TestSlashCompletionAppearsWhileTypingAndDoesNotEatQuery(t *testing.T) {
	m := newModel()
	for _, r := range "/mo" {
		next, _ := m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
		m = next.(model)
	}
	if m.modal != "slash" || len(m.modalValues) == 0 || m.modalValues[0] != "/model" {
		t.Fatalf("automatic completion missing: %q %#v", m.modal, m.modalValues)
	}
	if m.textarea.Value() != "/mo" {
		t.Fatalf("query keystrokes lost: %q", m.textarea.Value())
	}
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	m = next.(model)
	if cmd != nil || m.textarea.Value() != "/model" || m.modal != "" {
		t.Fatal("Tab completion must insert, not submit")
	}
}

func TestCompletedThinkingRetainsExpandableSource(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 30
	m.resize()
	m.applyEvent(event(`{"type":"assistant.reasoning_delta","delta":"one\ntwo\nthree\nREASONING_TAIL"}`))
	m.applyEvent(event(`{"type":"assistant.text_delta","delta":"**answer**"}`))
	m.applyEvent(event(`{"type":"turn.completed"}`))
	m.refreshTranscript()
	if !strings.Contains(ansi.Strip(m.viewport.View()), "thought") {
		t.Fatal("completed thinking header missing")
	}
	if strings.Contains(ansi.Strip(m.viewport.View()), "REASONING_TAIL") {
		t.Fatal("thinking tail starts collapsed")
	}
	next, _ := m.Update(tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl})
	m = next.(model)
	if !strings.Contains(ansi.Strip(m.viewport.View()), "REASONING_TAIL") {
		t.Fatal("completed reasoning was discarded")
	}
}

func TestCompletedToolCanBeExpandedAndCollapsedAfterCompletion(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 24
	m.resize()
	m.applyEvent(event(`{"type":"tool.started","tool_call_id":"t","tool_name":"read","arguments":{"path":"hello.go"}}`))
	m.applyEvent(event(`{"type":"tool.completed","tool_call_id":"t","tool_name":"read","result":"summary\nUNIQUE_TOOL_BODY","is_error":false}`))
	m.refreshTranscript()
	if strings.Contains(ansi.Strip(m.viewport.View()), "UNIQUE_TOOL_BODY") {
		t.Fatal("tool starts collapsed")
	}
	next, _ := m.Update(tea.KeyPressMsg{Code: 'o', Mod: tea.ModCtrl})
	m = next.(model)
	if !strings.Contains(ansi.Strip(m.viewport.View()), "UNIQUE_TOOL_BODY") {
		t.Fatalf("completed tool cannot be expanded: %s", ansi.Strip(m.viewport.View()))
	}
	next, _ = m.Update(tea.KeyPressMsg{Code: 'o', Mod: tea.ModCtrl})
	m = next.(model)
	if strings.Contains(ansi.Strip(m.viewport.View()), "UNIQUE_TOOL_BODY") {
		t.Fatal("completed tool cannot be collapsed")
	}
}

func TestKeyedWidgetUpdatesAndExpiresWithoutEnteringHistory(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 24
	m.resize()
	for _, raw := range []string{
		`{"type":"ui.render","render":{"slot":"widget","key":"w","body":{"type":"text","text":"old-widget"}}}`,
		`{"type":"ui.render","render":{"slot":"widget","key":"w","ttl_ms":100,"body":{"type":"text","text":"new-widget"}}}`,
	} {
		next, _ := m.Update(eventResult{ok: true, event: event(raw)})
		m = next.(model)
	}
	view := ansi.Strip(m.View().Content)
	if strings.Contains(view, "old-widget") || !strings.Contains(view, "new-widget") || len(m.transcript) != 0 {
		t.Fatal("widget was appended instead of replaced")
	}
	next, _ := m.Update(clockTick(time.Now().Add(time.Second)))
	m = next.(model)
	if strings.Contains(ansi.Strip(m.View().Content), "new-widget") {
		t.Fatal("widget TTL did not expire")
	}
}

func TestReplayedHistoryCannotBeOverwrittenByOldNoticeIndex(t *testing.T) {
	m := newModel()
	m.session = "one"
	m.host = &testHost{}
	m.applyEvent(event(`{"type":"ui.render","session_id":"one","render":{"slot":"notice","key":"n","body":{"type":"text","text":"old notice"}}}`))
	next, _ := m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(`{"items":[{"kind":"user","text":"persist me"}]}`)})
	m = next.(model)
	next, _ = m.Update(eventResult{ok: true, event: event(`{"type":"ui.render","session_id":"one","render":{"slot":"notice","key":"n","body":{"type":"text","text":"new notice"}}}`)})
	m = next.(model)
	if len(m.transcript) != 2 || m.transcript[0] != "> persist me" {
		t.Fatalf("old notice index overwrote history: %#v", m.transcript)
	}
}
