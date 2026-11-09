package main

import (
	"testing"

	"github.com/charmbracelet/colorprofile"
)

func TestStartupColorProfileHonorsExplicitTrueColorUnderScreen(t *testing.T) {
	env := []string{"TERM=screen-256color", "COLORTERM=truecolor"}
	if got := startupColorProfile(colorprofile.ANSI256, env); got != colorprofile.TrueColor {
		t.Fatalf("screen-256color with COLORTERM=truecolor: got %v, want TrueColor", got)
	}
}

func TestStartupColorProfileKeepsNoColor(t *testing.T) {
	env := []string{"TERM=screen-256color", "COLORTERM=truecolor", "NO_COLOR=1"}
	if got := startupColorProfile(colorprofile.ASCII, env); got != colorprofile.ASCII {
		t.Fatalf("NO_COLOR must survive COLORTERM=truecolor: got %v, want Ascii", got)
	}
}

func TestStartupColorProfileDisablesColorForNonEmptyNoColor(t *testing.T) {
	for _, value := range []string{"1", "0", "true", "false", "yes"} {
		env := []string{"TERM=screen-256color", "COLORTERM=truecolor", "NO_COLOR=" + value}
		if got := startupColorProfile(colorprofile.ANSI256, env); got != colorprofile.ASCII {
			t.Fatalf("NO_COLOR=%q must disable color: got %v, want Ascii", value, got)
		}
	}
	env := []string{"TERM=screen-256color", "COLORTERM=truecolor", "NO_COLOR="}
	if got := startupColorProfile(colorprofile.ANSI256, env); got != colorprofile.TrueColor {
		t.Fatalf("empty NO_COLOR must not disable color: got %v, want TrueColor", got)
	}
}

func TestStartupColorProfileKeepsNonTerminal(t *testing.T) {
	env := []string{"TERM=screen-256color", "COLORTERM=truecolor"}
	if got := startupColorProfile(colorprofile.NoTTY, env); got != colorprofile.NoTTY {
		t.Fatalf("a non-terminal must not be upgraded to truecolor: got %v, want NoTTY", got)
	}
}

func TestStartupColorProfileLeavesOtherProfilesAlone(t *testing.T) {
	cases := []struct {
		name     string
		detected colorprofile.Profile
		env      []string
		want     colorprofile.Profile
	}{
		{"real 256", colorprofile.ANSI256, []string{"TERM=screen-256color"}, colorprofile.ANSI256},
		{"plain xterm 256", colorprofile.ANSI256, []string{"TERM=xterm-256color"}, colorprofile.ANSI256},
		{"dumb", colorprofile.NoTTY, []string{"TERM=dumb", "COLORTERM=truecolor"}, colorprofile.NoTTY},
		{"explicit truecolor", colorprofile.ANSI256, []string{"TERM=tmux-256color", "COLORTERM=truecolor"}, colorprofile.TrueColor},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := startupColorProfile(tc.detected, tc.env); got != tc.want {
				t.Fatalf("%v: got %v, want %v", tc.env, got, tc.want)
			}
		})
	}
}
