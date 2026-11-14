package tui

import (
	tea "charm.land/bubbletea/v2"
	"testing"
)

func TestWheelTailIsRetiredWhenTypedPickerTakesFocus(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 14, 0)))
	first.FlushCmd()
	if got := w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 14, 0)); got != nil {
		t.Fatalf("not accumulated: %#v", got)
	}
	// Programmatic focus changes also retire a tail, even without a key barrier.
	m.sessionPicker.open = true
	m.sessionPickerEpoch++
	if got := w.Filter(m, clock.fire(t)); got != nil {
		t.Fatalf("transcript tail leaked into typed picker: %#v", got)
	}
}
