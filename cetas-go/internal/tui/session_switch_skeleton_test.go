package tui

import (
	"strconv"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The switch skeleton replaces the bare "loading session…" line: three dim bars
// of uneven width, then the label. Every row is exactly the pane width so the
// empty frame does not jump while `switch_session` composes the target.
func TestSwitchSkeletonLinesAreFullWidthBars(t *testing.T) {
	theme := newModel().theme()
	for _, width := range []int{24, 40, 76} {
		t.Run(strconv.Itoa(width), func(t *testing.T) {
			lines := switchSkeletonLines(theme, width)
			if len(lines) != 4 {
				t.Fatalf("%d cells: skeleton has %d lines, want 3 bars and the label", width, len(lines))
			}
			for i, line := range lines {
				if got := ansi.StringWidth(line); got != width {
					t.Fatalf("%d cells: line %d width = %d, want %d: %q", width, i, got, width, ansi.Strip(line))
				}
			}
			for i, line := range lines[:3] {
				bar := ansi.StringWidth(strings.TrimRight(ansi.Strip(line), " "))
				if bar >= width {
					t.Fatalf("%d cells: bar %d spans the whole width (%d cells): it is a rule, not a bar", width, i, bar)
				}
				if bar == 0 || strings.TrimSpace(ansi.Strip(line)) != strings.Repeat("─", bar) {
					t.Fatalf("%d cells: bar %d is not a box-drawing run: %q", width, i, ansi.Strip(line))
				}
			}
			if !strings.Contains(ansi.Strip(lines[3]), "loading session…") {
				t.Fatalf("%d cells: the label line was lost: %q", width, ansi.Strip(lines[3]))
			}
		})
	}
	if got := switchSkeletonLines(theme, 0); got != nil {
		t.Fatalf("a zero-width pane painted %#v", got)
	}
}

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
