package components

import (
	"fmt"
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

func askSteps(count int) string {
	lines := []string{}
	for i := 1; i <= count; i++ {
		lines = append(lines, fmt.Sprintf("- Step %d: do thing %d", i, i))
	}
	return strings.Join(lines, "\n")
}

func stripLines(lines []string) []string {
	out := make([]string, len(lines))
	for i, s := range lines {
		out[i] = ansi.Strip(s)
	}
	return out
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
