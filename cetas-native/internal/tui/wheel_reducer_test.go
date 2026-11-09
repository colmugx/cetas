package tui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestWheelReducerUsesOneRowPerNotchAndAggregateDistance(t *testing.T) {
	m := scrollWorkload("short_history")
	defer m.Close()
	initial := m.virtualScroll.top
	next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
	m = next.(model)
	if m.virtualScroll.top != initial-1 {
		t.Fatalf("one wheel report moved %d rows, want JS's one row", initial-m.virtualScroll.top)
	}
	next, _ = m.Update(WheelDeltaMsg{DeltaY: -7})
	m = next.(model)
	if m.virtualScroll.top != initial-8 {
		t.Fatalf("aggregated wheel distance was lost: top=%d want=%d", m.virtualScroll.top, initial-8)
	}
	next, _ = m.Update(WheelDeltaMsg{DeltaY: 1})
	m = next.(model)
	if m.virtualScroll.top != initial-7 {
		t.Fatal("reverse aggregate moved in the old direction")
	}
}
