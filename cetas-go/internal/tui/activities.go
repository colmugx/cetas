package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	ui "github.com/colmugx/cetas/cetas-go/internal/tui/components"
)

// These are projections of real extension facts, never task execution state.
// A background task has a longer clock than any one of its child turns.
// backgroundFinishGrace is how long a background child may sit in the
// finishing phase without a background_terminal event before it stops
// counting as an active agent.
const backgroundFinishGrace = 2 * time.Minute

type childActivity struct {
	child, nickname, kind, parentCall, taskID, model, effort string
	state, tool, tail, summary, questionID, question         string
	background, exited, terminal, childTurnDone              bool
	steps                                                    int
	started                                                  time.Time
	// turnDoneAt timestamps the settled turn of a parked background child;
	// live() uses it to expire the finishing phase.
	turnDoneAt time.Time
	history    []string
}

func (a *childActivity) live() bool {
	if a.state != "running" || a.exited || a.terminal {
		return false
	}
	// A background child parks in the "finishing" phase until its
	// authoritative background_terminal event lands. One that never reports
	// must not pin the dashboard's active count and a permanent 1 Hz redraw:
	// after the grace period it stops counting as live. An outstanding
	// question keeps it live regardless — its answer is still expected.
	if a.background && a.childTurnDone && a.questionID == "" &&
		!a.turnDoneAt.IsZero() && time.Since(a.turnDoneAt) > backgroundFinishGrace {
		return false
	}
	return true
}
func (a *childActivity) begin(call string, now time.Time) {
	a.parentCall, a.started, a.state = call, now, "running"
	a.steps, a.taskID, a.tool, a.tail, a.summary = 0, "", "", "", ""
	a.questionID, a.question = "", ""
	a.exited, a.terminal, a.childTurnDone = false, false, false
}
func (a *childActivity) log(text string) {
	if len(a.history) > 0 && a.history[len(a.history)-1] == text {
		return
	}
	a.history = append(a.history, text)
	if len(a.history) > 12 {
		a.history = a.history[len(a.history)-12:]
	}
}

// pruneQuestionOrder removes one settled question from the render walk so
// the order slice tracks the active set, not the session's full history.
func (s *activityState) pruneQuestionOrder(id string) {
	for i, candidate := range s.questionOrder {
		if candidate == id {
			s.questionOrder = append(s.questionOrder[:i:i], s.questionOrder[i+1:]...)
			return
		}
	}
}

type userQuestion struct {
	ID       string   `json:"question_id"`
	Short    string   `json:"short_id"`
	Text     string   `json:"question"`
	Kind     string   `json:"kind"`
	Options  []string `json:"options"`
	Deadline int64    `json:"deadline_at"`
}
type operationActivity struct {
	ID, Label, State, Detail string
	Current, Total           int64
	Started, Settled         time.Time
}

type activityState struct {
	host          map[string]*operationActivity
	hostOrder     []string
	records       map[string]*childActivity
	order         []string
	questions     map[string]userQuestion
	questionOrder []string
	settled       map[string]bool
	// expireNotice is bound by expireSurface right before the render-time
	// sweep in the same clock tick, so an expired question leaves the same
	// "⌛ … expired" trace js writes. It is consumed once per sweep: a binding
	// left over from an earlier frame copy must never fire into that frame.
	expireNotice func(id string)
	// Core projection bookkeeping (frozen `custom` schemas). taskReceipts
	// mirrors js's readyReceipts: one entry per background_outcome_ready,
	// keyed by task id and holding the receipt's own `session` field so a
	// foreign receipt never leaks into this session's waiting count;
	// deliveredTasks keeps a consumed receipt a no-op under replay.
	// wakeupNotices dedupes the single environment notice per executing
	// ticket envelope.
	taskReceipts   map[string]string
	deliveredTasks map[string]bool
	wakeupNotices  map[string]bool
}

func (s *activityState) expire(now time.Time) {
	for _, id := range append([]string(nil), s.hostOrder...) {
		item := s.host[id]
		if item != nil && !item.Settled.IsZero() && now.Sub(item.Settled) >= 15*time.Second {
			delete(s.host, id)
			for i, k := range s.hostOrder {
				if k == id {
					s.hostOrder = append(s.hostOrder[:i], s.hostOrder[i+1:]...)
					break
				}
			}
		}
	}
	// A stale binding must not survive into a later frame's sweep, so every
	// sweep requires expireSurface to have re-armed it moments before.
	notice := s.expireNotice
	s.expireNotice = nil
	for id, q := range s.questions {
		if q.Deadline > 0 && now.UnixMilli() > q.Deadline {
			delete(s.questions, id)
			s.pruneQuestionOrder(id)
			if s.settled == nil {
				s.settled = map[string]bool{}
			}
			s.settled[id] = true
			if notice != nil {
				notice(id)
			}
		}
	}
}

// questionExpiredNotice is the expiry trace js emits when its question ticker
// sweeps a parked ask: the question is gone, but the transcript still says so
// instead of it vanishing silently.
func (m *model) questionExpiredNotice(id string) {
	m.protocolNotice("⌛ " + strings.Replace(id, "question-", "@q", 1) + " expired before an answer arrived")
}

type tokenUsage struct{ Input, Output, Total, Cached, Responses int64 }

var childNicknames = []string{"apple", "banana", "cherry", "durian", "fig", "grape", "honeydew", "kiwi", "lemon", "mango", "nectarine", "orange", "papaya", "plum", "quince", "raspberry", "strawberry", "tangerine", "watermelon"}

func nickname(index int) string {
	name := childNicknames[index%len(childNicknames)]
	if round := index / len(childNicknames); round > 0 {
		name += fmt.Sprintf("-%d", round+1)
	}
	return name
}
func oneLine(text string) string { return strings.Join(strings.Fields(ui.Clean(text)), " ") }
func textTail(text string, limit int) string {
	r := []rune(text)
	if len(r) > limit {
		r = r[len(r)-limit:]
	}
	return string(r)
}
func preview(text string, limit int) string {
	r := []rune(oneLine(text))
	if len(r) > limit {
		return string(r[:limit]) + "…"
	}
	return string(r)
}

func (m *model) activityEvent(kind string, raw json.RawMessage) bool {
	s := &m.surface.activities
	switch kind {
	case "host.activity":
		var event struct {
			ID      string `json:"id"`
			Label   string `json:"label"`
			State   string `json:"state"`
			Detail  string `json:"detail"`
			Current int64  `json:"current"`
			Total   int64  `json:"total"`
		}
		if json.Unmarshal(raw, &event) != nil || event.ID == "" {
			return true
		}
		if event.State != "running" && event.State != "succeeded" && event.State != "failed" {
			return true
		}
		if s.host == nil {
			s.host = map[string]*operationActivity{}
		}
		item := s.host[event.ID]
		if item == nil {
			item = &operationActivity{Started: time.Now()}
			s.host[event.ID] = item
			s.hostOrder = append(s.hostOrder, event.ID)
			if len(s.hostOrder) > 12 {
				oldest := s.hostOrder[0]
				s.hostOrder = s.hostOrder[1:]
				delete(s.host, oldest)
			}
		}
		if event.State == "running" && !item.Settled.IsZero() {
			item.Settled = time.Time{}
			item.Started = time.Now()
		}
		item.ID, item.Label, item.State, item.Detail = event.ID, event.Label, event.State, event.Detail
		item.Current, item.Total = event.Current, event.Total
		if event.State != "running" && item.Settled.IsZero() {
			item.Settled = time.Now()
		}
		return true
	case "usage.delta":
		var u struct {
			Input  *int64 `json:"input_tokens"`
			Output *int64 `json:"output_tokens"`
			Total  *int64 `json:"total_tokens"`
			Cached *int64 `json:"cached_input_tokens"`
		}
		if err := json.Unmarshal(raw, &u); err != nil {
			m.err = "invalid usage: " + err.Error()
			return true
		}
		for _, item := range []struct {
			value *int64
			total *int64
		}{{u.Input, &m.surface.usage.Input}, {u.Output, &m.surface.usage.Output}, {u.Total, &m.surface.usage.Total}, {u.Cached, &m.surface.usage.Cached}} {
			if item.value != nil && *item.value >= 0 {
				*item.total += *item.value
			}
		}
		m.surface.usage.Responses++
		return true
	case "question.asked", "question.answered":
		var q userQuestion
		if err := json.Unmarshal(raw, &q); err != nil {
			m.err = "invalid question event: " + err.Error()
			return true
		}
		if q.ID == "" {
			m.err = "question event missing question_id"
			return true
		}
		if s.questions == nil {
			s.questions = map[string]userQuestion{}
			s.settled = map[string]bool{}
		}
		if kind == "question.answered" {
			delete(s.questions, q.ID)
			s.pruneQuestionOrder(q.ID)
			s.settled[q.ID] = true
			return true
		}
		if _, ok := s.questions[q.ID]; ok || s.settled[q.ID] {
			return true
		}
		if q.Kind != "confirm" && q.Kind != "select" {
			q.Kind = "input"
		}
		s.questions[q.ID] = q
		s.questionOrder = append(s.questionOrder, q.ID)
		return true
	case "subagent.event":
		var f struct {
			Child string          `json:"child_session"`
			Kind  string          `json:"kind"`
			Call  string          `json:"parent_call"`
			Ev    json.RawMessage `json:"ev"`
		}
		if err := json.Unmarshal(raw, &f); err != nil {
			m.err = "invalid subagent event: " + err.Error()
			return true
		}
		if f.Child == "" || len(f.Ev) == 0 {
			m.err = "subagent event missing child attribution"
			return true
		}
		m.foldChild(f.Child, f.Kind, f.Call, f.Ev)
		return true
	case "custom":
		var f struct {
			Source, Label string
			Child         string          `json:"child_session"`
			Call          string          `json:"parent_call"`
			Data          json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(raw, &f); err != nil {
			m.err = "invalid custom event: " + err.Error()
			return true
		}
		if f.Source == "posoco_ext_subagent" {
			if f.Child == "" {
				return false
			}
			m.foldChild(f.Child, "", f.Call, raw)
			return true
		}
		// Core custom facts (wakeup/operation/tasks/decision) are frozen
		// projections with dedicated renderings; js routes them ahead of the
		// generic foreign notice so the sources never fall through.
		switch f.Source {
		case "posoco.wakeup":
			return m.wakeupCustom(f.Label, coreFields(f.Data))
		case "posoco.tasks":
			return m.taskCustom(f.Label, coreFields(f.Data))
		case "posoco.decision":
			return m.decisionCustom(f.Label, coreFields(f.Data))
		case "posoco.operation":
			// js hands operation facts to its application layer and renders
			// nothing in the shell; go has no equivalent layer yet, so the
			// frames stay silent here rather than half-rendering as notices.
			return false
		}
		// Every other foreign source falls back to js's generic one-liner so
		// unknown publishers are never entirely invisible.
		m.protocolNotice("· " + f.Source + "/" + f.Label)
		return true
	}
	return false
}

// Core projection customs (docs/wakeup-decision-development.md "Shared event
// contract"): the runtime publishes wakeup/task/decision facts as plain
// `custom` observer events and the native observer forwards those frames
// unchanged, so these projections are what makes them visible. js's shell is
// the reference (terminal-shell.ts handleCoreCustom); its ambient header
// component is deliberately out of scope here. Parsing is defensive: a
// payload that breaks its frozen schema degrades to a notice built from
// whatever fields are still readable, never into m.err's sticky error state.

// coreFields decodes a projection payload without trusting its shape: a
// non-object body or a mistyped field simply reads as absent.
func coreFields(data json.RawMessage) map[string]any {
	fields := map[string]any{}
	if len(data) > 0 {
		_ = json.Unmarshal(data, &fields)
	}
	return fields
}

func coreString(fields map[string]any, key string) string {
	value, _ := fields[key].(string)
	return value
}

// coreSkewNotice degrades a matched core source whose payload breaks its
// frozen schema (version skew, bad payload): the notice lists whatever
// fields are still readable instead of guessing a success or tripping m.err.
// Field order follows the frozen contract so the line stays stable.
func (m *model) coreSkewNotice(source, label string, fields map[string]any) {
	parts := []string{}
	for _, key := range []string{
		"ticket_id", "tag", "envelope",
		"task_id", "session", "extension_id", "status",
		"call_id", "consumer", "provider", "purpose", "failure_mode", "model",
	} {
		if value := coreString(fields, key); value != "" {
			parts = append(parts, key+"="+preview(value, 40))
		}
	}
	if len(parts) == 0 {
		m.protocolNotice("⚠ malformed " + source + "/" + label)
		return
	}
	m.protocolNotice("⚠ malformed " + source + "/" + label + " · " + strings.Join(parts, " "))
}

// wakeupCustom mirrors js's wakeup projection: only the executing envelope
// renders, once per ticket; every other terminal is ambient-header
// bookkeeping the go host does not carry.
func (m *model) wakeupCustom(label string, fields map[string]any) bool {
	state := strings.TrimPrefix(label, "wakeup_")
	ticket := coreString(fields, "ticket_id")
	if !wakeupStates[state] || ticket == "" {
		m.coreSkewNotice("posoco.wakeup", label, fields)
		return true
	}
	if state == "executing" {
		if envelope := coreString(fields, "envelope"); envelope != "" {
			if m.surface.activities.wakeupNotices == nil {
				m.surface.activities.wakeupNotices = map[string]bool{}
			}
			if !m.surface.activities.wakeupNotices[ticket] {
				m.surface.activities.wakeupNotices[ticket] = true
				m.protocolNotice("◌ wakeup envelope — environment signal · " + preview(envelope, 200))
			}
		}
	}
	return true
}

var wakeupStates = map[string]bool{
	"requested": true, "executing": true, "satisfied": true, "completed": true,
	"failed": true, "cancelled": true, "dropped": true,
}

// taskCustom records a core background_outcome_ready receipt: it feeds only
// the waiting count, never the transcript, and attribution is the receipt's
// own frozen `session` field, not the host's current session.
func (m *model) taskCustom(label string, fields map[string]any) bool {
	if label != "background_outcome_ready" {
		m.coreSkewNotice("posoco.tasks", label, fields)
		return true
	}
	taskID := coreString(fields, "task_id")
	if taskID == "" {
		m.coreSkewNotice("posoco.tasks", label, fields)
		return true
	}
	s := &m.surface.activities
	if s.deliveredTasks[taskID] {
		return true
	}
	if s.taskReceipts == nil {
		s.taskReceipts = map[string]string{}
	}
	if _, seen := s.taskReceipts[taskID]; !seen {
		s.taskReceipts[taskID] = coreString(fields, "session")
	}
	return true
}

// deliverTaskReceipt closes one ready receipt on the extension's
// background_delivered ack — the same exact-once ack js keys its receipts by.
func (m *model) deliverTaskReceipt(taskID string) {
	if taskID == "" {
		return
	}
	s := &m.surface.activities
	if s.deliveredTasks == nil {
		s.deliveredTasks = map[string]bool{}
	}
	delete(s.taskReceipts, taskID)
	s.deliveredTasks[taskID] = true
}

// tasksWaiting counts ready-but-undelivered receipts for the current
// session: what js's resultsWaiting adds to its ambient line, wired into
// go's existing dashboard awaiting-reply count.
func (s *activityState) tasksWaiting(current string) int {
	count := 0
	for _, owner := range s.taskReceipts {
		if owner == "" || owner == current {
			count++
		}
	}
	return count
}

// decisionCustom mirrors js's decision projection: only failures render, as
// an error-styled transcript line; started/completed/cancelled stay silent
// so successful decisions never spam the transcript.
func (m *model) decisionCustom(label string, fields map[string]any) bool {
	kind := strings.TrimPrefix(label, "decision_")
	switch kind {
	case "started", "completed", "failed", "cancelled":
	default:
		m.coreSkewNotice("posoco.decision", label, fields)
		return true
	}
	if coreString(fields, "call_id") == "" {
		m.coreSkewNotice("posoco.decision", label, fields)
		return true
	}
	if kind != "failed" {
		return true
	}
	// js renders decision failures as errorNotice: an error-styled
	// transcript row, not m.err's sticky state.
	m.errorNoticeLine("⚠ decision failed (" + decisionFailureDiagnostic(fields) + ")")
	return true
}

// decisionFailureDiagnostic is js's bounded single-line attribution for a
// failed decision call: route, purpose and failure mode, omitting absent
// parts and falling back to the call id. Schema fields only — never payload
// bodies or raw errors.
func decisionFailureDiagnostic(fields map[string]any) string {
	consumer, provider := coreString(fields, "consumer"), coreString(fields, "provider")
	parts := []string{}
	if consumer != "" || provider != "" {
		if consumer == "" {
			consumer = "?"
		}
		if provider == "" {
			provider = "?"
		}
		parts = append(parts, consumer+"→"+provider)
	}
	if purpose := coreString(fields, "purpose"); purpose != "" {
		parts = append(parts, "purpose "+purpose)
	}
	if mode := coreString(fields, "failure_mode"); mode != "" {
		parts = append(parts, "mode "+mode)
	}
	if len(parts) == 0 {
		return coreString(fields, "call_id")
	}
	return strings.Join(parts, " · ")
}

func (m *model) foldChild(child, kind, call string, raw json.RawMessage) {
	var ev struct {
		Type, Source, Label, Delta, Message string
		Name                                string `json:"tool_name"`
		Data                                struct {
			Model, Effort, State, Summary, Detail, Question string
			Background                                      *bool  `json:"background"`
			Task                                            string `json:"task_id"`
			QuestionID                                      string `json:"question_id"`
			Superseded                                      bool   `json:"superseded"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &ev); err != nil {
		m.err = "invalid child fact: " + err.Error()
		return
	}
	if ev.Type == "custom" && ev.Source != "posoco_ext_subagent" {
		return
	}
	// The delivery ack carries only a task id: it closes the ready receipt
	// and never creates a record (js intercepts it before record folding).
	if ev.Type == "custom" && ev.Label == "background_delivered" {
		m.deliverTaskReceipt(ev.Data.Task)
		return
	}
	s := &m.surface.activities
	if s.records == nil {
		s.records = map[string]*childActivity{}
	}
	a := s.records[child]
	if a == nil {
		a = &childActivity{child: child, nickname: nickname(len(s.order)), kind: kind}
		realCall := call
		if call == "background" {
			realCall = ""
		}
		a.begin(realCall, time.Now())
		s.records[child] = a
		s.order = append(s.order, child)
	}
	if kind != "" {
		a.kind = kind
	}
	if ev.Type == "custom" {
		switch ev.Label {
		case "spawned":
			if call != "" && call != "background" && call != a.parentCall {
				a.begin(call, time.Now())
			}
			if ev.Data.Model != "" {
				a.model = ev.Data.Model
			}
			if ev.Data.Effort != "" {
				a.effort = ev.Data.Effort
			}
			if ev.Data.Background != nil {
				a.background = *ev.Data.Background
			}
		case "background_spawned":
			if at, ok := m.toolIndex[a.parentCall]; ok {
				m.removeNoticeBlock(at)
			}
			if a.terminal {
				return
			}
			a.background = true
			a.taskID = ev.Data.Task
		case "background_exited", "background_terminal":
			if a.terminal || ev.Data.Superseded {
				return
			}
			a.exited = true
			a.tool = ""
			a.questionID = ""
			a.question = ""
			if ev.Data.State != "" {
				a.state = ev.Data.State
			}
			if ev.Label == "background_terminal" {
				a.terminal = true
				a.summary = ev.Data.Summary
				m.protocolNotice(fmt.Sprintf("subagent(%s) · %s%s", a.nickname, a.state, func() string {
					if a.summary == "" {
						return ""
					}
					return " · " + oneLine(a.summary)
				}()))
			}
		case "question_asked":
			if a.live() && ev.Data.QuestionID != "" {
				a.questionID = ev.Data.QuestionID
				a.question = ev.Data.Question
				a.log("? " + preview(a.question, 80))
			}
		case "question_answered":
			if a.live() {
				a.questionID = ""
				a.question = ""
				a.log("✓ answered → child resumed")
			}
		}
		return
	}
	if ev.Type == "turn.started" && call != "" && call != "background" && call != a.parentCall {
		if a.parentCall == "" && a.live() {
			a.parentCall = call
		} else {
			a.begin(call, time.Now())
		}
	}
	if !a.live() {
		return
	}
	switch ev.Type {
	case "turn.started":
		a.steps++
		a.childTurnDone = false
		a.log(fmt.Sprintf("▸ step %d", a.steps))
	case "assistant.text_delta", "assistant.reasoning_delta":
		a.tail = textTail(a.tail+ev.Delta, 400)
	case "tool.started":
		a.tool = ev.Name
		a.log("▸ " + oneLine(ev.Name))
	case "tool.succeeded", "tool.failed", "tool.rejected", "tool.abandoned":
		a.tool = ""
	case "turn.completed", "turn.failed":
		a.childTurnDone = true
		a.tool = ""
		a.turnDoneAt = time.Now()
		if !a.background {
			a.state = "completed"
			if ev.Type == "turn.failed" {
				a.state = "failed"
				a.summary = ev.Message
			}
		}
	}
}
func elapsed(start time.Time) string {
	seconds := max(0, int(time.Since(start).Seconds()))
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	return fmt.Sprintf("%dm%02ds", seconds/60, seconds%60)
}
func (m model) activityLines(width, budget int) []string {
	s := m.surface.activities
	type row struct{ role, text string }
	rows := []row{}
	for i := len(s.hostOrder) - 1; i >= 0; i-- {
		item := s.host[s.hostOrder[i]]
		if item == nil {
			continue
		}
		marker, role := "▸", "accent"
		if item.State == "succeeded" {
			marker, role = "✓", "muted"
		}
		if item.State == "failed" {
			marker, role = "✗", "warning"
		}
		detail := oneLine(item.Detail)
		if item.Total > 0 && item.State == "running" {
			pct := min(100, 100*item.Current/item.Total)
			detail = fmt.Sprintf("%d%% · %.1f/%.1f MiB", pct, float64(item.Current)/(1<<20), float64(item.Total)/(1<<20))
		} else if item.Current > 0 && item.State == "running" {
			detail = fmt.Sprintf("%.1f MiB", float64(item.Current)/(1<<20))
		}
		label := marker + " " + item.Label
		if item.State == "running" {
			label += " · " + elapsed(item.Started)
		}
		if detail != "" {
			label += " · " + preview(detail, 70)
		}
		rows = append(rows, row{role, label})
	}
	for _, id := range s.questionOrder {
		if q, ok := s.questions[id]; ok {
			key := q.Short
			if key == "" {
				key = q.ID
			}
			rows = append(rows, row{"warning", fmt.Sprintf("? %s asks you · %s · /answer %s", key, preview(q.Text, 56), key)})
		}
	}
	for _, id := range s.order {
		a := s.records[id]
		if a.live() && a.questionID != "" {
			rows = append(rows, row{"warning", fmt.Sprintf("? subagent(%s) asks main · %s", a.nickname, preview(a.question, 56))})
		}
	}
	for _, id := range s.order {
		a := s.records[id]
		if !a.live() || !a.background || a.taskID == "" || a.questionID != "" {
			continue
		}
		phase := "thinking"
		if a.childTurnDone {
			phase = "finishing"
		}
		if a.tool != "" {
			phase = a.tool
		}
		rows = append(rows, row{"accent", fmt.Sprintf("⚡ subagent(%s) · %s %s · %s", a.nickname, a.kind, elapsed(a.started), phase)})
	}
	if len(rows) == 0 || width <= 0 {
		return nil
	}
	if width < 24 || budget < 3 {
		noun := "activities"
		if len(rows) == 1 {
			noun = "activity"
		}
		return []string{m.theme().Role("muted", ui.Fit(fmt.Sprintf("⚡ %d live %s", len(rows), noun), width))}
	}
	limit := min(4, budget)
	shown := min(len(rows), limit)
	if len(rows) > limit {
		shown--
	}
	lines := []string{}
	for _, row := range rows[:shown] {
		lines = append(lines, m.theme().Role(row.role, ui.Fit(row.text, width)))
	}
	if shown < len(rows) {
		lines = append(lines, m.theme().Role("muted", fmt.Sprintf("+ %d more activities", len(rows)-shown)))
	}
	return lines
}
func (m *model) openQuestion(key string) {
	for _, id := range m.surface.activities.questionOrder {
		q, ok := m.surface.activities.questions[id]
		if !ok || (key != "" && key != id && key != q.Short) {
			continue
		}
		prompt := uiPrompt{id: q.ID, kind: q.Kind, prompt: q.Text, options: q.Options}
		if m.modalRequestID != "" {
			if len(m.pendingUI) >= pendingUICap {
				m.err = "ask queue full; request cancelled"
				m.pendingAskReject = prompt.id
				return
			}
			m.pendingUI = append(m.pendingUI, prompt)
		} else {
			m.activateUI(prompt)
		}
		return
	}
	m.err = "No pending question matches " + key
}
func (m *model) questionCommand(value string) (tea.Cmd, bool) {
	fields := strings.Fields(value)
	if len(fields) == 0 {
		return nil, false
	}
	switch fields[0] {
	case "/questions":
		m.modal = "questions"
		m.modalPrompt = "Pending questions"
		m.modalItems = nil
		m.modalValues = nil
		m.modalIndex = 0
		for _, id := range m.surface.activities.questionOrder {
			if q, ok := m.surface.activities.questions[id]; ok {
				m.modalItems = append(m.modalItems, q.Short+" · "+preview(q.Text, 80))
				m.modalValues = append(m.modalValues, id)
			}
		}
		if len(m.modalItems) == 0 {
			m.modal = ""
			m.protocolNotice("No pending questions")
		}
		return nil, true
	case "/answer":
		if len(fields) > 2 {
			m.err = "Use /answer <question id> to open its typed answer panel"
		} else {
			key := ""
			if len(fields) > 1 {
				key = fields[1]
			}
			m.openQuestion(key)
		}
		return nil, true
	}
	return nil, false
}
