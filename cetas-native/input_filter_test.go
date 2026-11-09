package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/colmugx/cetas/cetas-native/internal/tui"
)

func TestStartupInputFilterKeepsColorPolicyAndWheelRouting(t *testing.T) {
	filter := startupInputFilter(colorprofile.ASCII, []string{"NO_COLOR=1"})
	if got := filter(nil, tea.CapabilityMsg{Content: "RGB"}); got != nil {
		t.Fatal("wheel filter replaced NO_COLOR capability protection")
	}
	msg := filter(nil, tea.ColorProfileMsg{Profile: colorprofile.TrueColor})
	if msg.(tea.ColorProfileMsg).Profile != colorprofile.ASCII {
		t.Fatal("late profile escaped the composed filter")
	}
	key := tea.KeyPressMsg{Code: 'x', Text: "x"}
	if filter(nil, key) != key {
		t.Fatal("composed filter delayed or changed a key")
	}
	wheel := filter(nil, tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 3, Y: 4}))
	delta, ok := wheel.(tui.WheelDeltaMsg)
	if !ok || delta.DeltaY != 1 || delta.Mouse.X != 3 || delta.Mouse.Y != 4 {
		t.Fatalf("production input filter did not route the initial wheel: %#v", wheel)
	}
	ordinary := startupInputFilter(colorprofile.ANSI256, nil)
	capability := tea.CapabilityMsg{Content: "RGB"}
	if ordinary(nil, capability) != capability {
		t.Fatal("ordinary terminal lost late capability negotiation")
	}
}
