package main

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
)

// startupColorProfile keeps Bubble Tea's detected profile except where a
// terminal behind screen/tmux explicitly declares truecolor, or where NO_COLOR
// disables color. The colorprofile Env chain deliberately ignores COLORTERM for
// those terminals, while Chalk's supports-color (and therefore the JS surface)
// returns level 3 for COLORTERM=truecolor. Matching that declaration keeps both
// surfaces on the same palette without forcing truecolor for terminals that did
// not claim it. NO_COLOR follows the no-color.org contract: any non-empty value
// disables color, even when COLORTERM=truecolor is present.
func startupColorProfile(detected colorprofile.Profile, env []string) colorprofile.Profile {
	if detected <= colorprofile.NoTTY {
		return detected
	}
	values := make(map[string]string, len(env))
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		values[key] = value
	}
	if noColor, ok := values["NO_COLOR"]; ok && noColor != "" {
		return colorprofile.ASCII
	}
	term := values["TERM"]
	muxed := strings.HasPrefix(term, "screen") || strings.HasPrefix(term, "tmux")
	if muxed && values["COLORTERM"] == "truecolor" {
		return colorprofile.TrueColor
	}
	return detected
}

// Bubble Tea accepts late RGB/Tc replies as an unconditional color upgrade.
// Capability discovery must not override the user's explicit NO_COLOR choice.
// No filter is installed for ordinary color negotiation or terminal input.
func startupColorFilter(profile colorprofile.Profile, env []string) func(tea.Model, tea.Msg) tea.Msg {
	noColor := ""
	for _, entry := range env {
		if value, ok := strings.CutPrefix(entry, "NO_COLOR="); ok {
			noColor = value
		}
	}
	if noColor == "" {
		return nil
	}
	return func(_ tea.Model, message tea.Msg) tea.Msg {
		switch msg := message.(type) {
		case tea.CapabilityMsg:
			if msg.Content == "RGB" || msg.Content == "Tc" {
				return nil
			}
		case tea.ColorProfileMsg:
			return tea.ColorProfileMsg{Profile: profile}
		}
		return message
	}
}
