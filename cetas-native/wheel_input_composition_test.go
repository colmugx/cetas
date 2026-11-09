package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/colmugx/cetas/cetas-native/internal/tui"
)

// The production filter runs color negotiation first and the wheel coalescer
// second, exactly like startupInputFilter. Coalescing must not swallow or
// rewrite capability/color messages, and ordinary input must still reach
// Update.
func TestWheelInputComposesWithExistingColorFilter(t *testing.T) {
	wheel := tui.NewWheelInput()
	color := startupColorFilter(colorprofile.ASCII, []string{"NO_COLOR=yes"})
	if color == nil {
		t.Fatal("NO_COLOR has no negotiation guard")
	}
	composed := func(m tea.Model, msg tea.Msg) tea.Msg {
		if color != nil {
			msg = color(m, msg)
			if msg == nil {
				return nil
			}
		}
		return wheel.Filter(m, msg)
	}

	for _, capability := range []string{"RGB", "Tc"} {
		if got := composed(nil, tea.CapabilityMsg{Content: capability}); got != nil {
			t.Fatalf("wheel composition permitted late %s upgrade: %#v", capability, got)
		}
	}
	profile, ok := composed(nil, tea.ColorProfileMsg{Profile: colorprofile.TrueColor}).(tea.ColorProfileMsg)
	if !ok || profile.Profile != colorprofile.ASCII {
		t.Fatalf("wheel composition overrode NO_COLOR: %#v", profile)
	}
	key := tea.KeyPressMsg{Code: 'x', Text: "x"}
	if got := composed(nil, key); got != key {
		t.Fatalf("wheel composition rewrote ordinary input: %#v", got)
	}

	wheelUp := func(x, y int) tea.MouseWheelMsg {
		return tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp, X: x, Y: y, Mod: tea.ModShift})
	}
	first, ok := composed(nil, wheelUp(4, 9)).(tui.WheelDeltaMsg)
	if !ok {
		t.Fatal("first wheel notch did not reach Update through the composed filter")
	}
	if first.DeltaY != -1 {
		t.Fatalf("first wheel notch = %d, want -1", first.DeltaY)
	}
	first.FlushCmd()
	if got := composed(nil, wheelUp(4, 9)); got != nil {
		t.Fatalf("same-window wheel notch bypassed coalescing: %#v", got)
	}
}
