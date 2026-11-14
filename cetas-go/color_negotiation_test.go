package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
)

func TestNoColorSurvivesLateCapabilityUpgrade(t *testing.T) {
	filter := startupColorFilter(colorprofile.ASCII, []string{"NO_COLOR=yes"})
	if filter == nil {
		t.Fatal("NO_COLOR has no negotiation guard")
	}
	for _, capability := range []string{"RGB", "Tc"} {
		if got := filter(nil, tea.CapabilityMsg{Content: capability}); got != nil {
			t.Fatalf("NO_COLOR permitted late %s upgrade: %#v", capability, got)
		}
	}
	profile := filter(nil, tea.ColorProfileMsg{Profile: colorprofile.TrueColor}).(tea.ColorProfileMsg)
	if profile.Profile != colorprofile.ASCII {
		t.Fatal("color-profile update overrode NO_COLOR")
	}
	key := tea.KeyPressMsg{Code: 'x', Text: "x"}
	if got := filter(nil, key); got != key {
		t.Fatal("color policy consumed ordinary input")
	}
	other := tea.CapabilityMsg{Content: "other"}
	if got := filter(nil, other); got != other {
		t.Fatal("color policy consumed unrelated terminal capability")
	}
	if startupColorFilter(colorprofile.ANSI256, nil) != nil {
		t.Fatal("ordinary auto-detection unexpectedly disabled capability upgrades")
	}
}
