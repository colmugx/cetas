package components

import (
	"strings"

	"charm.land/lipgloss/v2"
)

type WelcomeState string
type WelcomeVersion struct{ Version, Channel string }
type WelcomeSource struct {
	Cwd, Home string
	State     WelcomeState
	Rows      int
	Version   *WelcomeVersion
}

var modularCut = []string{"  ▄█▀▄████▀ ", "▄█▀         ", "▀▄          ", "██          ", "▀█▄    ▄▄   ", "  ▀████▄▀█▄ "}

// One square pixel per design unit: the scale where both cuts in the mark are a
// full cell wide, at the cost of five more rows.
var modularCutLarge = []string{
	"    ▄███▀ ▄█████████▀ ",
	"  ▄███▀ ▄█████████▀   ",
	"▄███▀                 ",
	"██▀                   ",
	"▀ ▄█                  ",
	"▄███                  ",
	"████                  ",
	"████                  ",
	"▀███▄        ▄▄▄▄     ",
	"  ▀█████████▄ ▀███▄   ",
	"    ▀█████████▄ ▀███▄ ",
}

func Welcome(t Theme, s WelcomeSource, width int, compact bool) []string {
	if width <= 0 {
		return nil
	}
	workspace := Clean(s.Cwd)
	home := strings.TrimRight(Clean(s.Home), "/\\")
	if home != "" {
		if workspace == home {
			workspace = "~"
		} else if strings.HasPrefix(workspace, home+"/") || strings.HasPrefix(workspace, home+"\\") {
			workspace = "~" + workspace[len(home):]
		}
	}
	brand := lipgloss.NewStyle().Bold(true).Render(t.Role("brand", "cetas"))
	muted := func(s string) string { return t.Role("muted", s) }
	fit := func(s string) string { return Fit(s, width) }
	setup := s.State == "needs_setup"
	starting := s.State == ""
	rows := s.Rows
	if rows == 0 {
		rows = 24
	}
	if compact || width < 40 || rows < 22 {
		out := []string{fit(" " + brand + " " + muted("· "+workspace))}
		if !compact && setup && width >= 24 {
			out = append(out, fit(" "+muted("/login to connect a provider")))
		}
		return out
	}
	cardWidth := min(width-2, 88)
	contentWidth := cardWidth - 4
	border := func(a, b string) string { return " " + muted(a+strings.Repeat("─", cardWidth-2)+b) }
	row := func(s string) string { return " " + muted("│ ") + Pad(s, contentWidth) + muted(" │") }
	title := brand
	if s.Version != nil {
		title += muted(" " + s.Version.Version + " · " + s.Version.Channel)
	}
	context := []string{title, muted("One agent. Every surface."), "", muted("Workspace  ") + workspace, muted("Built on Posoco"), ""}
	logo := modularCut
	if width >= 64 && rows >= 34 {
		logo = modularCutLarge
	}
	lines := context
	if len(logo) > len(context) {
		lead := (len(logo) - len(context)) / 2
		lines = make([]string, 0, len(logo))
		for range lead {
			lines = append(lines, "")
		}
		lines = append(lines, context...)
		for len(lines) < len(logo) {
			lines = append(lines, "")
		}
	}
	out := []string{"", border("╭", "╮"), row("")}
	if width >= 64 {
		for i, c := range lines {
			out = append(out, row(t.Role("brand", logo[i])+"   "+c))
		}
	} else {
		for _, i := range []int{0, 1, 3, 4} {
			out = append(out, row(context[i]))
		}
	}
	out = append(out, row(""), border("╰", "╯"))
	guidance, shortcuts := "", ""
	if starting {
		guidance = muted("Starting your workspace…")
	} else if setup {
		if width < 64 {
			guidance = t.Role("brand", "/login") + muted(" connect  ·  ") + t.Role("brand", "/model") + muted(" choose")
		} else {
			guidance = t.Role("brand", "/login") + muted(" connect a provider  ·  ") + t.Role("brand", "/model") + muted(" choose a model")
		}
	} else {
		if width < 64 {
			guidance = muted("Describe a task. ") + t.Role("brand", "/help") + muted(" for commands.")
		} else {
			guidance = muted("Describe a task to begin. ") + t.Role("brand", "/help") + muted(" for commands.")
		}
	}
	if setup || starting {
		if width < 64 {
			shortcuts = muted("Shared settings · ~/.cetas/")
		} else {
			shortcuts = muted("Your credentials and model choice are shared across Cetas.")
		}
	} else {
		if width < 64 {
			shortcuts = t.Role("brand", "@path") + muted(" files  ·  ") + t.Role("brand", "/sessions") + muted(" history")
		} else {
			shortcuts = t.Role("brand", "@path") + muted(" add a file  ·  ") + t.Role("brand", "/sessions") + muted(" resume work")
		}
	}
	return append(out, fit(" "+guidance), fit(" "+shortcuts), "")
}
