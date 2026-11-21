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

func TestExpiredQuestionLeavesExpiryTrace(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-2","short_id":"@q2","question":"Expired","kind":"input","deadline_at":1}`))
	m.applyEvent(event(`{"type":"question.asked","question_id":"question-1","short_id":"@q1","question":"Pending","kind":"input"}`))
	// The render-time sweep (expireSurface + activities.expire) runs in the
	// clock tick; js announces every expiry and the trace must survive it.
	next, _ := m.Update(clockTick(time.Now().Add(time.Second)))
	m = next.(model)
	if len(m.surface.activities.questions) != 1 || m.surface.activities.questions["question-1"].ID == "" {
		t.Fatalf("unexpired question swept: %#v", m.surface.activities.questions)
	}
	joined := strings.Join(m.transcript, "\n")
	if !strings.Contains(joined, "⌛ @q2 expired before an answer arrived") {
		t.Fatalf("expired question deleted without a trace: %q", joined)
	}
	if strings.Contains(joined, "@q1") {
		t.Fatalf("pending question announced as expired: %q", joined)
	}
}

func TestForeignCustomEventsLeaveFallbackNotice(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"custom","source":"acme.ext","label":"ping"}`))
	if len(m.transcript) != 1 || !strings.Contains(m.transcript[0], "· acme.ext/ping") {
		t.Fatalf("foreign custom dropped silently: %#v", m.transcript)
	}
	// Core sources never reach the generic fallback: posoco.operation is
	// application-layer owned and stays silent, and the three rendered
	// projections carry their own shapes — malformed payloads degrade to a
	// dedicated skew notice instead of half-rendering as `· source/label`.
	before := len(m.transcript)
	m.applyEvent(event(`{"type":"custom","source":"posoco.operation","label":"operation_started","data":{"operation_id":"op-1","session":"s-1","origin":"turn"}}`))
	if len(m.transcript) != before {
		t.Fatalf("posoco.operation rendered in the shell: %#v", m.transcript)
	}
	for _, source := range []string{"posoco.wakeup", "posoco.tasks", "posoco.decision"} {
		m.applyEvent(event(`{"type":"custom","source":"` + source + `","label":"payload"}`))
	}
	if len(m.transcript) != before+3 {
		t.Fatalf("core custom sources lost their dedicated handling: %#v", m.transcript)
	}
	for _, line := range m.transcript[before:] {
		if strings.Contains(line, "· posoco.") {
			t.Fatalf("core custom hit the foreign fallback: %q", line)
		}
	}
	// Subagent customs keep folding into child activity, not the notice path.
	m.applyEvent(event(`{"type":"custom","source":"posoco_ext_subagent","label":"spawned","child_session":"child","parent_call":"spawn-1","data":{"background":false}}`))
	if m.surface.activities.records["child"] == nil {
		t.Fatalf("subagent custom no longer folds into child activity: %#v", m.transcript)
	}
}

func TestCoreDecisionFailureLeavesOnePayloadFreeErrorLine(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"custom","source":"posoco.decision","label":"decision_failed","data":{"call_id":"d1","consumer":"posoco_ext_permission","provider":"auto_allow","purpose":"tool_gate","failure_mode":"fail_closed","state":"SECRET-REQUEST-BODY"}}`))
	if len(m.transcript) != 1 || !strings.Contains(m.transcript[0], "decision failed") ||
		!strings.Contains(m.transcript[0], "posoco_ext_permission→auto_allow") ||
		!strings.Contains(m.transcript[0], "purpose tool_gate") ||
		!strings.Contains(m.transcript[0], "mode fail_closed") {
		t.Fatalf("decision failure diagnostic lost: %#v", m.transcript)
	}
	if m.blocks[len(m.transcript)-1].Kind != "error" {
		t.Fatalf("decision failure not error-styled: %#v", m.blocks[len(m.transcript)-1])
	}
	if strings.Contains(strings.Join(m.transcript, "\n"), "SECRET-REQUEST-BODY") {
		t.Fatal("decision failure rendered payload fields")
	}
	// started/completed/cancelled never render; successes must not spam.
	before := len(m.transcript)
	for _, label := range []string{"decision_started", "decision_completed", "decision_cancelled"} {
		m.applyEvent(event(`{"type":"custom","source":"posoco.decision","label":"` + label + `","data":{"call_id":"d2","consumer":"posoco_ext_permission"}}`))
	}
	if len(m.transcript) != before {
		t.Fatalf("non-failed decisions rendered: %#v", m.transcript)
	}
	// Without attribution the diagnostic falls back to the call id.
	m.applyEvent(event(`{"type":"custom","source":"posoco.decision","label":"decision_failed","data":{"call_id":"d5"}}`))
	if len(m.transcript) != before+1 || !strings.Contains(m.transcript[before], "decision failed (d5)") {
		t.Fatalf("bare call-id fallback lost: %#v", m.transcript)
	}
}

func TestCoreWakeupEnvelopeNoticesOncePerTicket(t *testing.T) {
	m := newModel()
	envelope := `{"type":"custom","source":"posoco.wakeup","label":"wakeup_executing","data":{"ticket_id":"t1","session":"s-1","tag":"build-watch","extension_id":"posoco_ext_subagent","ticket_enqueued_at":1,"envelope":"[posoco-wakeup tag=build-watch] build  failed"}}`
	m.applyEvent(event(envelope))
	m.applyEvent(event(envelope))
	if len(m.transcript) != 1 ||
		!strings.Contains(m.transcript[0], "wakeup envelope — environment signal") ||
		!strings.Contains(m.transcript[0], "build failed") {
		t.Fatalf("wakeup envelope notice lost or duplicated: %#v", m.transcript)
	}
	// Every other wakeup terminal is ambient-header bookkeeping the go host
	// does not carry, so none of them renders a transcript line.
	before := len(m.transcript)
	for _, label := range []string{"wakeup_requested", "wakeup_satisfied", "wakeup_completed", "wakeup_executing"} {
		m.applyEvent(event(`{"type":"custom","source":"posoco.wakeup","label":"` + label + `","data":{"ticket_id":"t1","session":"s-1","tag":"build-watch","extension_id":"posoco_ext_subagent"}}`))
	}
	if len(m.transcript) != before {
		t.Fatalf("non-envelope wakeup terminals rendered: %#v", m.transcript)
	}
}

func TestCoreTaskReceiptsFeedDashboardWaitingCount(t *testing.T) {
	m := newModel()
	m.session = "s-1"
	m.width, m.height = 108, 36
	receipt := `{"type":"custom","source":"posoco.tasks","label":"background_outcome_ready","data":{"task_id":"task_1","session":"s-1","extension_id":"posoco_ext_subagent","label":"explore","status":"completed"}}`
	m.applyEvent(event(receipt))
	// Receipts carry no transcript noise; duplicates are no-ops.
	m.applyEvent(event(receipt))
	if len(m.transcript) != 0 {
		t.Fatalf("task receipt rendered as transcript noise: %#v", m.transcript)
	}
	// Attribution is the receipt's own session: a foreign receipt never
	// leaks into this session's waiting count.
	m.applyEvent(event(`{"type":"custom","source":"posoco.tasks","label":"background_outcome_ready","data":{"task_id":"task_2","session":"s-other","extension_id":"posoco_ext_subagent","label":"explore","status":"failed"}}`))
	if waiting := m.surface.activities.tasksWaiting("s-1"); waiting != 1 {
		t.Fatalf("receipt waiting count wrong: %d", waiting)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); !strings.Contains(screen, "1 awaiting reply") {
		t.Fatalf("receipt absent from dashboard: %q", screen)
	}
	// The extension's background_delivered ack closes the matching receipt.
	m.applyEvent(event(`{"type":"custom","source":"posoco_ext_subagent","label":"background_delivered","child_session":"c-1","parent_call":"background","data":{"task_id":"task_1","child_session":"c-1"}}`))
	if waiting := m.surface.activities.tasksWaiting("s-1"); waiting != 0 {
		t.Fatalf("delivered receipt still waiting: %d", waiting)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); strings.Contains(screen, "awaiting reply") {
		t.Fatalf("dashboard kept a delivered receipt: %q", screen)
	}
	// A replayed receipt for a consumed task stays a no-op.
	m.applyEvent(event(receipt))
	if waiting := m.surface.activities.tasksWaiting("s-1"); waiting != 0 {
		t.Fatalf("delivered task resurrected its receipt: %d", waiting)
	}
}
