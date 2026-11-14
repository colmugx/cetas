package main

import (
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/colmugx/cetas/cetas-go/internal/tui"
)

// Bubble Tea installs one filter, not a filter stack. Preserve terminal color
// policy before coalescing mouse input so NO_COLOR cannot be lost at startup.
func startupInputFilter(profile colorprofile.Profile, env []string) func(tea.Model, tea.Msg) tea.Msg {
	colors := startupColorFilter(profile, env)
	wheel := tui.NewWheelInput()
	return func(model tea.Model, message tea.Msg) tea.Msg {
		if colors != nil {
			message = colors(model, message)
			if message == nil {
				return nil
			}
		}
		return wheel.Filter(model, message)
	}
}
