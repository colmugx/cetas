package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
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
	turnDoneAt                                               time.Time
	history                                                  []string
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
type activityState struct {
	records       map[string]*childActivity
	order         []string
	questions     map[string]userQuestion
	questionOrder []string
	settled       map[string]bool
}

func (s *activityState) expire(now time.Time) {
	for id, q := range s.questions {
		if q.Deadline > 0 && now.UnixMilli() > q.Deadline {
			delete(s.questions, id)
			s.pruneQuestionOrder(id)
			if s.settled == nil {
				s.settled = map[string]bool{}
			}
			s.settled[id] = true
		}
	}
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
		if f.Source != "posoco_ext_subagent" || f.Child == "" {
			return false
		}
		m.foldChild(f.Child, "", f.Call, raw)
		return true
	}
	return false
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
