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

func TestStartupColorProfileKeepsNonTerminal(t *testing.T) {
	env := []string{"TERM=screen-256color", "COLORTERM=truecolor"}
	if got := startupColorProfile(colorprofile.NoTTY, env); got != colorprofile.NoTTY {
		t.Fatalf("a non-terminal must not be upgraded to truecolor: got %v, want NoTTY", got)
	}
}
