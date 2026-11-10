package tui

import (
	"encoding/base64"
	"strings"
	"testing"

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
