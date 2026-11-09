package tui

import (
	"fmt"
	"strings"

	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

func (m model) activityForCall(call string) *childActivity {
	if call == "" || call == "background" {
		return nil
	}
	for _, child := range m.surface.activities.order {
		if a := m.surface.activities.records[child]; a.parentCall == call {
			return a
		}
	}
	return nil
}
func (m model) decorateAgentCall(call, rendered string) string {
	a := m.activityForCall(call)
	if a == nil || a.background {
		return rendered
	}
	model := a.model
	if a.effort != "" {
		model += "(" + a.effort + ")"
	}
	parts := []string{a.kind}
	if model != "" {
		parts = append(parts, model)
	}
	parts = append(parts, elapsed(a.started), fmt.Sprintf("step %d", a.steps))
	if a.tool != "" {
		parts = append(parts, a.tool)
	}
	detail := strings.Join(parts, " · ")
	rendered += "\n   " + m.theme().Role("muted", ui.Fit(detail, max(1, m.viewport.Width()-3)))
	if a.questionID != "" {
		rendered += "\n   " + m.theme().Role("warning", ui.Fit("→ "+a.nickname+" asks · "+a.questionID+" · "+preview(a.question, 80), max(1, m.viewport.Width()-3)))
	}
	if m.showTools {
		start := max(0, len(a.history)-8)
		for _, line := range a.history[start:] {
			rendered += "\n   " + m.theme().Role("muted", ui.Fit(line, max(1, m.viewport.Width()-3)))
		}
	} else if a.tail != "" {
		rendered += "\n   " + m.theme().Role("muted", ui.Fit("⋮ "+oneLine(a.tail), max(1, m.viewport.Width()-3)))
	}
	return rendered
}
