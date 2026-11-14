package transcript

// The expanded (ctrl+o) view steps every other detail line out by one column so
// a long argument or result body is easier to scan. It is a rendering-only
// gutter: the collapsed row keeps its one-line summary and the block's raw text
// — what the copy path reads — is never rewritten.

import (
	"encoding/json"
	"strings"
	"testing"
)

// detailIndents splits a rendered tool row into its head line and the leading
// space count of every detail line.
func detailIndents(t *testing.T, rendered string) (head string, indents []int) {
	t.Helper()
	lines := strings.Split(rendered, "\n")
	head = lines[0]
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			t.Fatalf("blank detail line in the row: %#v", lines)
		}
		indents = append(indents, len(line)-len(strings.TrimLeft(line, " ")))
	}
	return head, indents
}

func TestExpandedToolDetailLinesAlternateIndent(t *testing.T) {
	const width = 80
	// detailIndent is the six-column summary indent plus the Text component's
	// single leading column; the zebra gutter adds the seventh on odd rows.
	const detailIndent = 7
	for _, tc := range []struct {
		name  string
		block Block
	}{
		{
			name: "read",
			block: Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"big.txt"}`),
				Text: "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7"},
		},
		{
			name: "write",
			block: Block{Kind: "tool", Name: "write", State: "succeeded", Arguments: json.RawMessage(`{"path":"b.ts"}`),
				Text: "w0\nw1\nw2\nw3\nw4\nw5\nw6"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, indents := detailIndents(t, tc.block.Render(Options{Width: width, Now: parityNow})); len(indents) != 1 {
				t.Fatalf("collapsed row must stay a one-line summary: %#v", indents)
			}
			head, indents := detailIndents(t, tc.block.Render(Options{Width: width, ToolsExpanded: true, Now: parityNow}))
			if !strings.HasPrefix(head, " ●") {
				t.Fatalf("expanded row lost its head line: %q", head)
			}
			if len(indents) < zebraDetailLines {
				t.Fatalf("expanded row has %d detail lines, want at least %d", len(indents), zebraDetailLines)
			}
			for i, indent := range indents {
				want := detailIndent
				if i%2 == 1 {
					want++
				}
				if indent != want {
					t.Fatalf("detail line %d indent = %d, want %d (indents %#v)", i, indent, want, indents)
				}
			}
		})
	}
}

func TestShortExpandedBodyKeepsTheEvenIndent(t *testing.T) {
	block := Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"small.txt"}`),
		Text: "a\nb\nc"}
	_, indents := detailIndents(t, block.Render(Options{Width: 80, ToolsExpanded: true, Now: parityNow}))
	if len(indents) != 3 {
		t.Fatalf("short body rendered %d detail lines: %#v", len(indents), indents)
	}
	for i, indent := range indents {
		if indent != 7 {
			t.Fatalf("detail line %d indent = %d, want the plain six-column indent", i, indent)
		}
	}
}

func TestZebraGutterDoesNotTouchTheRawText(t *testing.T) {
	raw := "l0\nl1\nl2\nl3\nl4\nl5"
	block := Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"big.txt"}`), Text: raw}
	if out := block.Render(Options{Width: 80, ToolsExpanded: true, Now: parityNow}); !strings.Contains(out, " l1") {
		t.Fatalf("expanded row lost its zebra gutter: %q", out)
	}
	if block.Text != raw {
		t.Fatalf("rendering rewrote the copy source: %q", block.Text)
	}
}
