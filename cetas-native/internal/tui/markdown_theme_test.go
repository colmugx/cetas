package tui

import (
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestMarkdownThemeTracksTerminalColorsAndKeepsText(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 30
	m.resize()
	m.appendAssistant("# Heading\n\nSome **strong** and `code`.\n\n- first\n- second")
	m.reflow()
	before := m.markdownRenderer
	next, _ := m.Update(tea.BackgroundColorMsg{Color: color.RGBA{255, 255, 255, 255}})
	m = next.(model)
	if m.markdownRenderer == before {
		t.Fatal("late terminal background did not rebuild Markdown theme")
	}
	rendered := m.mountedTranscriptBlock(0)
	if !strings.Contains(rendered, "38;2;0;103;128") || !strings.Contains(rendered, "38;2;134;87;0") {
		t.Fatalf("Markdown did not use source light accent/code colors: %q", rendered)
	}
	plain := ansi.Strip(rendered)
	for _, source := range []string{"Heading", "strong", "code", "first", "second"} {
		if !strings.Contains(plain, source) {
			t.Fatalf("Markdown lost %q: %s", source, plain)
		}
	}
}
