package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The skeleton owns the status region for the length of the switch and gives it
// back to the ordinary status label afterwards.
func TestSwitchStatusRegionPaintsTheSkeleton(t *testing.T) {
	m := newModel()
	m.session = "s-current"
	m.status = "ready"
	m.switchInFlight = "s-target"
	lines := m.regions().status
	w, _ := m.dimensions()
	if len(lines) != 4 {
		t.Fatalf("switching status has %d lines, want the 3-bar skeleton plus its label: %#v", len(lines), lines)
	}
	for i, line := range lines {
		if got := ansi.StringWidth(line); got != w {
			t.Fatalf("status line %d width = %d, want %d", i, got, w)
		}
	}
	m.switchInFlight = ""
	m.status = "thinking"
	if lines := m.regions().status; len(lines) != 1 || !strings.Contains(ansi.Strip(lines[0]), "thinking") {
		t.Fatalf("a finished switch kept the skeleton: %#v", lines)
	}
}
