package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func TestBackgroundActivityHasSeparateTurnAndTerminalClocks(t *testing.T) {
	m := newModel()
	m.session = "parent"
	for _, raw := range []string{
		`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"spawn-1","ev":{"type":"custom","source":"posoco_ext_subagent","label":"spawned","data":{"background":true,"model":"opaque/model","effort":"high"}}}`,
		`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"custom","source":"posoco_ext_subagent","label":"background_spawned","data":{"task_id":"task-1"}}}`,
		`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"turn.started"}}`,
		`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"tool.started","tool_name":"read","tool_call_id":"child-read"}}`,
		`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"turn.completed"}}`,
	} {
		m.applyEvent(event(raw))
	}
	if len(m.transcript) != 0 || len(m.toolIndex) != 0 {
		t.Fatal("child tool polluted parent transcript")
	}
	a := m.surface.activities.records["child"]
	if a == nil || !a.live() || a.parentCall != "spawn-1" || a.steps != 1 {
		t.Fatalf("child turn killed or rekeyed background task: %#v", a)
	}
	lines := strings.Join(m.activityLines(100, 10), "\n")
	if !strings.Contains(lines, "subagent(apple)") || !strings.Contains(lines, "finishing") {
		t.Fatalf("missing activity projection: %s", lines)
	}
	terminal := `{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"custom","source":"posoco_ext_subagent","label":"background_terminal","data":{"state":"failed","summary":"diagnostic"}}}`
	m.applyEvent(event(terminal))
	m.applyEvent(event(terminal))
	m.applyEvent(event(`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"turn.started"}}`))
	if a.live() || a.state != "failed" || len(m.transcript) != 1 || !strings.Contains(m.transcript[0], "diagnostic") {
		t.Fatalf("terminal not authoritative/exactly once: %#v %#v", a, m.transcript)
	}
	m.applyEvent(event(`{"type":"subagent.event","session_id":"parent","child_session":"child","kind":"explore","parent_call":"spawn-2","ev":{"type":"custom","source":"posoco_ext_subagent","label":"spawned","data":{"background":true}}}`))
	if !a.live() || a.parentCall != "spawn-2" || a.nickname != "apple" || a.terminal {
		t.Fatal("explicit resume did not reset run while keeping nickname")
	}
}

func TestQuestionsArePriorityLiveObligationsNotOrdinaryInput(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-1","short_id":"@q1","question":"Choose colour","kind":"select","options":["Red","Blue"]}`))
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-2","short_id":"@q2","question":"Expired","kind":"input","deadline_at":1}`))
	m.surface.activities.expire(time.Now())
	lines := strings.Join(m.activityLines(80, 8), "\n")
	if !strings.Contains(lines, "/answer @q1") || strings.Contains(lines, "Expired") {
		t.Fatalf("question routing/expiry lost: %s", lines)
	}
	m.applyEvent(event(`{"type":"turn.completed"}`))
	if len(m.surface.activities.questions) != 1 {
		t.Fatal("ordinary turn settled unrelated question")
	}
	m.applyEvent(event(`{"type":"question.answered","question_id":"question-1"}`))
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-1","question":"stale"}`))
	if len(m.surface.activities.questions) != 0 {
		t.Fatal("replay resurrected answered question")
	}
}

func TestActivityHeaderDegradesAndQuestionCanOpenInlineWithoutSubmittingDraft(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-1","short_id":"@q1","question":"Confirm?","kind":"confirm"}`))
	if got := ansi.Strip(strings.Join(m.activityLines(20, 8), "\n")); got != "⚡ 1 live activity" {
		t.Fatalf("narrow header: %q", got)
	}
	m.textarea.SetValue("keep draft")
	m.command("/answer @q1")
	if m.modalRequestID != "question-1" || m.modal != "confirm" || m.textarea.Value() != "keep draft" {
		t.Fatal("answer did not focus actual question")
	}
}

func TestForegroundAgentMetadataAndBackgroundCallSuppression(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"tool.started","tool_call_id":"spawn-1","tool_name":"subagent","arguments":{"task":"investigate"}}`))
	m.applyEvent(event(`{"type":"subagent.event","child_session":"child","kind":"explore","parent_call":"spawn-1","ev":{"type":"custom","source":"posoco_ext_subagent","label":"spawned","data":{"background":false,"model":"opaque/model","effort":"high"}}}`))
	m.applyEvent(event(`{"type":"subagent.event","child_session":"child","kind":"explore","parent_call":"spawn-1","ev":{"type":"turn.started"}}`))
	text, _ := m.renderBlock(0)
	if !strings.Contains(ansi.Strip(text), "opaque/model(high)") || !strings.Contains(text, "step 1") {
		t.Fatalf("foreground metadata not correlated with real parent call: %s", text)
	}
	m.applyEvent(event(`{"type":"subagent.event","child_session":"child","kind":"explore","parent_call":"spawn-1","ev":{"type":"custom","source":"posoco_ext_subagent","label":"spawned","data":{"background":true}}}`))
	m.applyEvent(event(`{"type":"subagent.event","child_session":"child","kind":"explore","parent_call":"background","ev":{"type":"custom","source":"posoco_ext_subagent","label":"background_spawned","data":{"task_id":"task"}}}`))
	m.applyEvent(event(`{"type":"tool.completed","tool_call_id":"spawn-1","tool_name":"subagent","result":"accepted"}`))
	if len(m.transcript) != 0 {
		t.Fatalf("background call leaked into history: %#v", m.transcript)
	}
}

func TestUsageIsAccumulatedWithoutInventingMissingTotals(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"usage.delta","input_tokens":10,"output_tokens":3,"total_tokens":null}`))
	m.applyEvent(event(`{"type":"usage.delta","input_tokens":null,"output_tokens":2,"total_tokens":12}`))
	if m.surface.usage.Input != 10 || m.surface.usage.Output != 5 || m.surface.usage.Total != 12 || m.surface.usage.Responses != 2 {
		t.Fatalf("usage facts lost: %#v", m.surface.usage)
	}
}
