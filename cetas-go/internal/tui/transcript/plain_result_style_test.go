package transcript

// The JS fallback renderer builds its result body as
// `new Text(line1 + "\n" + body, 1, 0)`: the head keeps the state/title
// styles, but the body inherits the terminal's default foreground. The native
// port used to wrap the whole body in theme.muted
// (cetas-go/internal/tui/transcript/block.go plainResultBlock), which is
// the extra dimming this test pins out. Row styles still have to land.

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFallbackResultBodyKeepsDefaultForeground(t *testing.T) {
	styles := probeStyles()
	cases := []struct {
		name     string
		expanded bool
		text     string
		body     []string
	}{
		{name: "web_search", text: "first line\nsecond line", body: []string{" first line", " second line"}},
		{name: "subagent", text: "first line\nsecond line", body: []string{" first line", " second line"}},
		{name: "web_search", expanded: true, text: "l0\nl1\nl2\nl3", body: []string{" l0", " l1", " l2", " l3"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			block := Block{
				Kind:      "tool",
				Name:      tc.name,
				State:     "succeeded",
				Arguments: json.RawMessage(`{"query":"x"}`),
				Text:      tc.text,
			}
			out := block.Render(Options{Width: 80, ToolsExpanded: tc.expanded, Styles: styles, Now: parityNow})
			lines := strings.Split(out, "\n")
			want := append([]string{" " + probeSuccess + "●" + probeReset + " " + probeTitle + tc.name + probeReset}, tc.body...)
			if strings.Join(lines, "\n") != strings.Join(want, "\n") {
				t.Fatalf("row differs from the JS fallback layout\n got: %#v\nwant: %#v", lines, want)
			}
			for _, body := range lines[1:] {
				if strings.Contains(body, probeMuted) {
					t.Fatalf("result body kept the extra muted style: %q", body)
				}
			}
		})
	}
}
