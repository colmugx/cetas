package components

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// Expectations below are the ansi-stripped output of the JS oracle
// (cetas-js/ui/extension-ui.ts AskPanel rendered through UiRequestBar), not
// re-derived from the Go implementation.

func resetAskBodies() {
	askBodies.Lock()
	askBodies.entries = nil
	askBodies.renders = 0
	askBodies.Unlock()
}

func askBodyRenders() int {
	askBodies.Lock()
	defer askBodies.Unlock()
	return askBodies.renders
}

func askLines(t *testing.T, req AskRequest, width, selected int, value string, expanded bool) []string {
	t.Helper()
	lines := stripLines(Ask(Theme{}, req, width, selected, value, expanded))
	for _, line := range lines {
		if ansi.StringWidth(line) > width {
			t.Fatalf("width %d exceeded: %q", width, line)
		}
		for _, r := range line {
			if r == '\x1b' || (r < 0x20 && r != ' ') {
				t.Fatalf("control character leaked into %q", line)
			}
		}
	}
	return lines
}

func TestAskCollapsesLongBodyButKeepsEveryLineAndExactCount(t *testing.T) {
	resetAskBodies()
	title := "Choose an option\n" + askSteps(40)
	req := AskRequest{Kind: AskSelect, Title: title, Options: []string{"Approve", "Revise", "Dismiss"}}
	collapsed := askLines(t, req, 80, 0, "", false)
	body := collapsed[1 : len(collapsed)-3]
	if len(body) != askPreviewLines {
		t.Fatalf("preview must show %d lines, got %d", askPreviewLines, len(body))
	}
	if !strings.Contains(strings.Join(collapsed, "\n"), "… (+25 lines, ctrl+o to expand)") {
		t.Fatalf("missing exact overflow label: %q", collapsed)
	}
	if !strings.Contains(collapsed[len(collapsed)-1], "ctrl+o expand") {
		t.Fatalf("footer must name the expand key: %q", collapsed[len(collapsed)-1])
	}
	expanded := askLines(t, req, 80, 0, "", true)
	steps := 0
	for _, line := range expanded {
		if strings.Contains(line, "do thing") {
			steps++
		}
	}
	if steps != 40 {
		t.Fatalf("expanded body truncated: %d/40 lines", steps)
	}
	if strings.Contains(strings.Join(expanded, "\n"), "(+") {
		t.Fatal("expanded body must not carry the overflow label")
	}
	if !strings.HasSuffix(strings.TrimRight(expanded[len(expanded)-1], " "), "ctrl+o collapse") {
		t.Fatalf("expanded footer must offer collapse: %q", expanded[len(expanded)-1])
	}
	// A body of exactly the preview size stays whole and uncollapsed.
	short := askLines(t, AskRequest{Kind: AskSelect, Title: "Q\n" + askSteps(askPreviewLines), Options: []string{"A", "B"}}, 80, 0, "", false)
	if strings.Contains(strings.Join(short, "\n"), "ctrl+o") {
		t.Fatalf("15-line body must not collapse: %q", short)
	}
	// Confirm bodies are plain text and never collapse (the JS oracle only
	// collapses the markdown select body).
	confirm := askLines(t, AskRequest{Kind: AskConfirm, Prompt: "Q\n" + askSteps(20)}, 40, 0, "", false)
	detail := 0
	for _, line := range confirm {
		if strings.Contains(line, "do thing") {
			detail++
		}
	}
	if detail != 20 || strings.Contains(strings.Join(confirm, "\n"), "ctrl+o") {
		t.Fatalf("confirm detail collapsed: %q", confirm)
	}
}

func TestAskSanitizesPromptOptionsAndValue(t *testing.T) {
	hostile := "\x1b[31mred\x1b[0m\x00\x07\nsecond\x1b]0;pwned\x07"
	for _, req := range []AskRequest{
		{Kind: AskSelect, Title: hostile, Options: []string{hostile, "Deny"}},
		{Kind: AskConfirm, Prompt: hostile},
		{Kind: AskInput, Prompt: hostile, Placeholder: hostile},
		{Kind: AskSecret, Prompt: hostile},
	} {
		for _, width := range []int{8, 24, 80} {
			askLines(t, req, width, 0, hostile, false)
			askLines(t, req, width, 0, hostile, true)
		}
	}
	// A secret never shows its value, and masks one bullet per rune.
	secret := askLines(t, AskRequest{Kind: AskSecret, Prompt: "API key"}, 24, 0, "秘密-secret", false)
	joined := strings.Join(secret, "\n")
	if strings.Contains(joined, "secret") || !strings.Contains(joined, "••••••") {
		t.Fatalf("secret leaked or mis-masked: %q", secret)
	}
}

func TestAskStaysInsideEveryWidth(t *testing.T) {
	requests := []AskRequest{
		{Kind: AskSelect, Title: "Pick\n- a\n- b\n- c", Options: []string{"一", "二", "三", "四", "五", "六", "七", "八", "九", "十"}},
		{Kind: AskConfirm, Prompt: "Q\nsecond line"},
		{Kind: AskInput, Prompt: "Name", Placeholder: "e.g. release-1"},
		{Kind: AskSecret, Prompt: "Token"},
		{Kind: AskSelect, Title: PlanReviewTitlePrefix + " plan\nbody"},
		{Kind: AskSelect, Options: []string{"only"}},
		{Kind: AskSelect, Title: "", Options: nil},
	}
	for _, req := range requests {
		for width := 1; width <= 90; width++ {
			for _, selected := range []int{-1, 0, 3, 99} {
				askLines(t, req, width, selected, "value", false)
				askLines(t, req, width, selected, "value", true)
			}
		}
	}
	if Ask(Theme{}, requests[0], 0, 0, "", false) != nil {
		t.Fatal("zero width must render nothing")
	}
}

func TestAskBodyIsRenderedOncePerWidthAndText(t *testing.T) {
	resetAskBodies()
	body := strings.TrimSuffix(strings.Repeat("- a very long plan step that wraps\n", 4000), "\n")
	req := AskRequest{Kind: AskSelect, Title: "Plan\n" + body, Options: []string{"Approve", "Deny"}}
	Ask(Theme{}, req, 80, 0, "", false)
	warm := askBodyRenders()
	for frame := 0; frame < 20; frame++ {
		lines := Ask(Theme{}, req, 80, 0, "", false)
		if len(lines) != askPreviewLines+4 {
			t.Fatalf("frame %d rendered %d lines", frame, len(lines))
		}
	}
	if got := askBodyRenders(); got != warm {
		t.Fatalf("collapsed preview re-wrapped the body: %d -> %d renders", warm, got)
	}
	// The expanded body comes from the same cached lines: no extra render and
	// no truncation of the body.
	expanded := Ask(Theme{}, req, 80, 0, "", true)
	if got := askBodyRenders(); got != warm {
		t.Fatalf("expanding re-wrapped the body: %d renders", got)
	}
	if len(expanded) != 4000+3 {
		t.Fatalf("expanded body lost lines: %d", len(expanded))
	}
	// A different width is a different layout, and the cache stays bounded.
	for width := 60; width < 60+2*askBodyCacheSize; width++ {
		Ask(Theme{}, req, width, 0, "", false)
	}
	askBodies.Lock()
	cached := len(askBodies.entries)
	askBodies.Unlock()
	if cached > askBodyCacheSize {
		t.Fatalf("body cache grew to %d entries", cached)
	}
}
