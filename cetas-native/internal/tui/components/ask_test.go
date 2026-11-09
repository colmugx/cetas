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

func TestAskButtonRowVersusStackedList(t *testing.T) {
	req := AskRequest{Kind: AskSelect, Title: "Allow tool 'bash' (shell)?", Options: []string{"Allow once", "Allow for this session", "Deny"}}
	row := askLines(t, req, 60, 0, "", false)
	want := []string{
		"Allow tool 'bash' (shell)?                                  ",
		" Allow once   Allow for this session   Deny ",
		" ←→ choose · ⏎ confirm · esc cancel",
	}
	if strings.Join(row, "\n") != strings.Join(want, "\n") {
		t.Fatalf("row layout\nwant:%q\ngot: %q", want, row)
	}
	stacked := askLines(t, req, 24, 0, "", false)
	want = []string{
		"Allow tool 'bash'       ",
		"(shell)?                ",
		" Allow once             ",
		"Allow for this session",
		"Deny",
		" ↑↓ choose · ⏎ confirm ·",
	}
	if strings.Join(stacked, "\n") != strings.Join(want, "\n") {
		t.Fatalf("stacked layout\nwant:%q\ngot: %q", want, stacked)
	}
}

func TestAskOptionViewportKeepsSelectionCentred(t *testing.T) {
	options := make([]string, 20)
	for i := range options {
		options[i] = fmt.Sprintf("opt%d", i+1)
	}
	req := AskRequest{Kind: AskSelect, Title: "Pick", Options: options}
	cases := []struct {
		selected int
		want     []string
	}{
		{5, []string{"Pick                    ", "opt2", "opt3", "opt4", "opt5", " opt6                   ", "opt7", "opt8", "opt9", " (6/20)", " ↑↓ choose · ⏎ confirm ·"}},
		{12, []string{"Pick                    ", "opt9", "opt10", "opt11", "opt12", " opt13                  ", "opt14", "opt15", "opt16", " (13/20)", " ↑↓ choose · ⏎ confirm ·"}},
	}
	for _, c := range cases {
		got := askLines(t, req, 24, c.selected, "", false)
		if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
			t.Fatalf("selected %d\nwant:%q\ngot: %q", c.selected, c.want, got)
		}
	}
	// Exactly eight options need no counter and no scrolling.
	eight := askLines(t, AskRequest{Kind: AskSelect, Title: "Pick", Options: options[:8]}, 24, 0, "", false)
	if len(eight) != 1+8+1 || strings.Contains(strings.Join(eight, "\n"), "/8)") {
		t.Fatalf("eight options should not scroll: %q", eight)
	}
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

func TestAskPlanReviewRendersSelectorOnly(t *testing.T) {
	title := PlanReviewTitlePrefix + " big plan\n\n" + askSteps(40) + "\n\nAccept, revise with feedback, or dismiss?"
	req := AskRequest{Kind: AskSelect, Title: title, Options: []string{"Approve — accept the plan and implement it", "Revise", "Dismiss"}}
	lines := askLines(t, req, 80, 0, "", false)
	want := []string{
		"Plan awaiting approval: big plan                                                ",
		" Approve — accept the plan and implement it   Revise   Dismiss ",
		" ←→ choose · ⏎ confirm · esc cancel",
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("plan review\nwant:%q\ngot: %q", want, lines)
	}
	// The same body on a confirm prompt is not a plan review: the JS oracle
	// gates the special case on the select request type.
	confirm := askLines(t, AskRequest{Kind: AskConfirm, Prompt: title}, 80, 0, "", false)
	if !strings.Contains(strings.Join(confirm, "\n"), "do thing") {
		t.Fatal("confirm prompt lost its detail")
	}
}

func TestAskBodyRendersMarkdownBlocks(t *testing.T) {
	cases := []struct {
		name string
		body string
		want []string
	}{
		{"heading", "# Heading\nbody", []string{"Heading", "", "body"}},
		{"fence", "```\ncode line\n```\nafter", []string{"```", "  code line", "```", "", "after"}},
		{"paragraph", "First detail\nSecond detail", []string{"First detail", "Second detail"}},
		{"inline", "**bold** and `code` and *em*", []string{"bold and code and em"}},
		{"intraword", "model_x_y and a*b*c", []string{"model_x_y and abc"}},
		{"nested", "- a\n  - b\n- c", []string{"- a", "    - b", "- c"}},
		{"ordered-nested", "1. a\n   1. b\n2. c", []string{"1. a", "    1. b", "2. c"}},
		{"rule", "---\ntext", []string{strings.Repeat("─", 40), "", "text"}},
		{"tilde-fence", "~~~\nx\n~~~\ny", []string{"```", "  x", "```", "", "y"}},
		{"blanks-collapse", "a\n\n\nb", []string{"a", "", "b"}},
		{"indented", "   indented paragraph", []string{"   indented paragraph"}},
		{"list-inline-code", "- run `go test ./...` now", []string{"- run go test ./... now"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := askLines(t, AskRequest{Kind: AskSelect, Title: "Q\n" + c.body, Options: []string{"A", "B"}}, 40, 0, "", false)
			body := got[1 : len(got)-2]
			trimmed := make([]string, len(body))
			for i, line := range body {
				trimmed[i] = strings.TrimRight(line, " ")
			}
			if strings.Join(trimmed, "\n") != strings.Join(c.want, "\n") {
				t.Fatalf("want:%q\ngot: %q", c.want, trimmed)
			}
		})
	}
}

func TestAskWrapsCJKWithoutOverflow(t *testing.T) {
	// Wide characters wrap greedily, one grapheme at a time.
	got := askLines(t, AskRequest{Kind: AskSelect, Title: "问\n这是一段很长的中文正文需要换行显示的内容", Options: []string{"是", "否"}}, 24, 0, "", false)
	want := []string{
		"问                      ",
		"这是一段很长的中文正文需",
		"要换行显示的内容        ",
		" 是   否 ",
		" ←→ choose · ⏎ confirm ·",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("cjk body\nwant:%q\ngot: %q", want, got)
	}
	// A long unbroken token is hard-wrapped instead of overflowing.
	got = askLines(t, AskRequest{Kind: AskSelect, Title: "Q\nsupercalifragilisticexpialidocious", Options: []string{"A", "B"}}, 20, 0, "", false)
	if !strings.Contains(got[1], "supercalifragilistic") || !strings.Contains(got[2], "expialidocious") {
		t.Fatalf("long token not hard-wrapped: %q", got)
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
