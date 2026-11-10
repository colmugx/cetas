package tui

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

func TestFormatProgramStatusMatchesProtocol(t *testing.T) {
	working := formatProgramStatus(programStatus{state: "working", msg: "Working"})
	want := "\x1b]7501;state=working:app=cetas:msg=" + base64.StdEncoding.EncodeToString([]byte("Working")) + "\x1b\\"
	if working != want {
		t.Fatalf("working report: %q want %q", working, want)
	}
	idle := formatProgramStatus(programStatus{state: "idle"})
	if idle != "\x1b]7501;state=idle:app=cetas\x1b\\" {
		t.Fatalf("idle report: %q", idle)
	}
	blocked := formatProgramStatus(programStatus{state: "blocked", kind: "auth", msg: "Waiting for authentication"})
	if !strings.HasPrefix(blocked, "\x1b]7501;state=blocked:app=cetas:kind=auth:msg=") {
		t.Fatalf("blocked report: %q", blocked)
	}
	clear := formatProgramStatus(programStatus{state: "clear"})
	if clear != "\x1b]7501;state=clear:app=cetas\x1b\\" {
		t.Fatalf("clear report: %q", clear)
	}
	// kind never rides non-blocked reports.
	if strings.Contains(idle, "kind=") || strings.Contains(working, "kind=") {
		t.Fatal("kind leaked onto a non-blocked report")
	}
}

func TestStatusMessageBudget(t *testing.T) {
	if got := truncateStatusMessage("  plain  "); got != "plain" {
		t.Fatalf("trim: %q", got)
	}
	// Control characters become spaces; the printable remainder of a stray
	// escape sequence survives as text, exactly as pi-tui's filter behaves.
	if got := truncateStatusMessage("a\x00\x1b[2Jb"); got != "a  [2Jb" {
		t.Fatalf("control stripping: %q", got)
	}
	long := strings.Repeat("你", 2000) // 6000 bytes > 2048 budget
	if got := truncateStatusMessage(long); len(got) > 2048 {
		t.Fatalf("byte budget exceeded: %d", len(got))
	}
}

func TestProjectProgramStatusPriority(t *testing.T) {
	m := newModel()
	// Before first attach: starting.
	if got := m.projectProgramStatus(); got.state != "working" || got.msg != "Starting" {
		t.Fatalf("boot projection: %#v", got)
	}
	// Attached and idle.
	m.session = "s-1"
	if got := m.projectProgramStatus(); got.state != "idle" {
		t.Fatalf("idle projection: %#v", got)
	}
	// A running turn outranks idle.
	m.running = true
	if got := m.projectProgramStatus(); got.state != "working" || got.msg != "Working" {
		t.Fatalf("working projection: %#v", got)
	}
	// Setup outranks idle work.
	m.running = false
	m.needsSetup = true
	if got := m.projectProgramStatus(); got.state != "blocked" || got.kind != "auth" {
		t.Fatalf("setup projection: %#v", got)
	}
	// Questions outrank setup.
	m.pendingUI = []uiPrompt{{id: "u-1", kind: "input"}}
	if got := m.projectProgramStatus(); got.state != "blocked" || got.kind != "question" {
		t.Fatalf("question projection: %#v", got)
	}
	// Authentication outranks questions.
	m.authID = "auth-1"
	if got := m.projectProgramStatus(); got.state != "blocked" || got.kind != "auth" {
		t.Fatalf("auth projection: %#v", got)
	}
	// Shutdown clears everything.
	m.status = "MoonBit host stopped"
	if got := m.projectProgramStatus(); got.state != "clear" {
		t.Fatalf("clear projection: %#v", got)
	}
}

func TestEmitProgramStatusDedupes(t *testing.T) {
	m := newModel()
	m.session = "s-1"
	first := m.emitProgramStatus()
	if first == nil {
		t.Fatal("first state change must report")
	}
	if again := m.emitProgramStatus(); again != nil {
		t.Fatal("unchanged state must not report again")
	}
	m.running = true
	if changed := m.emitProgramStatus(); changed == nil {
		t.Fatal("state change must report again")
	}
}

// cmdMsgs flattens one level of tea.Batch so tests can drive every real
// command beside the terminal status report.
func cmdMsgs(t *testing.T, cmd tea.Cmd) []tea.Msg {
	t.Helper()
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok {
		msgs := make([]tea.Msg, 0, len(batch))
		for _, child := range batch {
			if child != nil {
				msgs = append(msgs, child())
			}
		}
		return msgs
	}
	return []tea.Msg{msg}
}

func TestTerminalChromeTitleAndUnfocusedNotice(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.focused = true
	m.surface.cwd = "/work/cetas-native"
	m.requestTitle()
	if m.pendingTitle == "" {
		t.Fatal("cwd change must stage a title")
	}
	cmd := m.emitTerminalChrome()
	if cmd == nil || m.lastTitle != "cetas · cetas-native" || m.pendingTitle != "" {
		t.Fatalf("title not flushed/deduped: %q", m.lastTitle)
	}
	if again := m.emitTerminalChrome(); again != nil {
		t.Fatal("unchanged title must not emit again")
	}
	// A focused terminal never gets completion notifications.
	m.requestNotice("Cetas: turn completed")
	if m.pendingNotice != "" {
		t.Fatal("focused terminal must not stage a notification")
	}
	m.focused = false
	m.requestNotice("Cetas: turn failed")
	if m.pendingNotice == "" {
		t.Fatal("unfocused terminal must stage the notification")
	}
	if cmd := m.emitTerminalChrome(); cmd == nil || m.pendingNotice != "" {
		t.Fatal("notification not flushed exactly once")
	}
}

func TestCompletionDebounceFiresOnceAndValidatesToken(t *testing.T) {
	host := &switchRecordingHost{}
	m := newModel()
	m.host = host
	m.textarea.SetValue("read @doc")
	next, _ := m.Update(tea.KeyPressMsg{Text: "s"})
	state := next.(model)
	if state.completionDueAt.IsZero() {
		t.Fatal("typing staged no completion request")
	}
	for _, name := range host.names {
		if name == "file_search" {
			t.Fatal("debounced request fired before the deadline")
		}
	}
	// Typing settles: the deadline passes and the pump fires exactly one.
	state.completionDueAt = time.Now().Add(-time.Millisecond)
	fired, cmd := state.Update(struct{}{})
	final := fired.(model)
	saw := false
	for _, msg := range cmdMsgs(t, cmd) {
		if result, ok := msg.(commandResult); ok && strings.HasPrefix(result.name, "complete:") {
			saw = true
		}
	}
	if !saw {
		t.Fatalf("settled typing did not fire one completion: %#v", cmdMsgs(t, cmd))
	}
	if !final.completionDueAt.IsZero() {
		t.Fatal("fired request left its deadline armed")
	}
	before := len(host.names)
	// A stale deadline with a moved caret must not fire anything.
	final.completionDueAt = time.Now().Add(-time.Millisecond)
	final.textarea.SetValue("plain text")
	if again, _ := final.Update(struct{}{}); again == nil {
		t.Fatal("update returned no model")
	}
	if len(host.names) != before {
		t.Fatal("stale completion fired without a token under the caret")
	}
}
