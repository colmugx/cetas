package components

import (
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"image/color"
	"reflect"
	"strings"
	"testing"
)

func i64(n int64) *int64 { return &n }
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
func TestWelcomeSourceFixtures(t *testing.T) {
	for _, c := range welcomeGolden {
		t.Run(c.name, func(t *testing.T) {
			got := stripLines(Welcome(Theme{}, c.source, c.width, c.compact))
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("want:\n%q\ngot:\n%q", c.want, got)
			}
		})
	}
}
func TestDashboardSourceFixtures(t *testing.T) {
	for _, c := range dashboardGolden {
		t.Run(c.name, func(t *testing.T) {
			got := stripLines(Dashboard(Theme{}, c.entries, c.width, c.ctx))
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("want:\n%q\ngot:\n%q", c.want, got)
			}
		})
	}
}

// askSelected mirrors the JS panel's initial selection: default_index ?? 0 for
// selects and default_yes ? 0 : 1 for confirms.
func askSelected(r AskRequest) int {
	switch r.Kind {
	case AskConfirm:
		if r.DefaultYes {
			return 0
		}
		return 1
	case AskSelect:
		if r.DefaultIndex >= 0 && r.DefaultIndex < len(r.Options) {
			return r.DefaultIndex
		}
	}
	return 0
}
func TestAskSourceFixtures(t *testing.T) {
	for _, c := range askGolden {
		t.Run(c.name, func(t *testing.T) {
			got := stripLines(Ask(Theme{}, c.req, c.width, askSelected(c.req), "", false))
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("want:\n%q\ngot:\n%q", c.want, got)
			}
		})
	}
}
func TestContextOccupancySourceFixtures(t *testing.T) {
	for _, c := range occupancyGolden {
		t.Run(c.name, func(t *testing.T) {
			got, ok := ContextOccupancy(c.state)
			if got != c.want || ok != c.ok {
				t.Fatalf("got %q,%v want %q,%v", got, ok, c.want, c.ok)
			}
		})
	}
}
func TestThemeNeverGuessesSurfaceWhenColorsUnknown(t *testing.T) {
	for _, theme := range []Theme{{}, {FG: color.White}, {BG: color.Black}} {
		if theme.Surface("user", "text") != "text" {
			t.Fatal("unknown fg/bg produced fixed surface")
		}
	}
}
func TestAskMasksSecretAndBoundsLongOptions(t *testing.T) {
	req := AskRequest{Kind: AskSecret, Prompt: "API key"}
	out := Ask(Theme{}, req, 24, 0, "secret-canary", false)
	joined := strings.Join(out, "\n")
	if strings.Contains(joined, "secret-canary") || !strings.Contains(joined, "••••") {
		t.Fatal("secret prompt is not masked")
	}
	for _, w := range []int{1, 18, 24, 40, 80} {
		out = Ask(Theme{}, AskRequest{Kind: AskSelect, Title: "你好 👩‍💻", Options: []string{strings.Repeat("路径", 100), "Deny"}}, w, 0, "", false)
		for _, line := range out {
			if ansi.StringWidth(line) > w {
				t.Fatalf("ask exceeds width %d: %q", w, line)
			}
		}
	}
}
