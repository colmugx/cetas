package tui

import (
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// The transcript owns every gutter, so a Markdown render must not carry a
// trailing blank row of its own: a kept row would silently add a second row to
// the gap before whatever block comes next.
func TestMarkdownRenderDropsTheTrailingBlankRows(t *testing.T) {
	for _, width := range []int{20, 80} {
		renderer, err := newMarkdownRenderer(width, ui.Theme{})
		if err != nil {
			t.Fatalf("w=%d: renderer: %v", width, err)
		}
		rendered, err := renderMarkdown(renderer, "answer body\n\nsecond paragraph")
		if err != nil {
			t.Fatalf("w=%d: render: %v", width, err)
		}
		lines := strings.Split(rendered, "\n")
		if last := lines[len(lines)-1]; strings.TrimSpace(ansi.Strip(last)) == "" {
			t.Fatalf("w=%d: render kept a trailing blank row: %q", width, rendered)
		}
		plain := ansi.Strip(rendered)
		if !strings.Contains(plain, "answer body") || !strings.Contains(plain, "second paragraph") {
			t.Fatalf("w=%d: render lost content: %q", width, plain)
		}
		// The break between the two paragraphs is content, not a trailing row.
		plainLines := strings.Split(plain, "\n")
		first, second, blank := -1, -1, false
		for index, line := range plainLines {
			switch {
			case strings.Contains(line, "answer body"):
				first = index
			case strings.Contains(line, "second paragraph"):
				second = index
			}
			if first >= 0 && second < 0 && strings.TrimSpace(line) == "" {
				blank = true
			}
		}
		if first < 0 || second <= first || !blank {
			t.Fatalf("w=%d: render lost the paragraph break: %q", width, plain)
		}
	}
}

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
