package components

import (
	"image/color"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestPanelFixedKeepsGeometryAcrossListLengths(t *testing.T) {
	theme := NewTheme(color.Gray{Y: 230}, color.Black)
	heights := map[int]int{}
	for _, count := range []int{0, 1, 3, 9, 40} {
		items := make([]string, count)
		for i := range items {
			items[i] = string(rune('a' + i%26))
		}
		rows := PanelFixed(theme, "Model", items, count-1, 40, 30, 9)
		heights[len(rows)]++
		if len(rows) != 13 { // 4 chrome rows + fixed 9-row pane
			t.Fatalf("count %d: panel height %d, want 13", count, len(rows))
		}
		for _, row := range rows {
			if w := ansi.StringWidth(row); w != 40 {
				t.Fatalf("row width %d, want 40: %q", w, row)
			}
		}
	}
	empty := PanelFixed(theme, "Model", nil, 0, 40, 30, 9)
	if !rowHas(empty, "(no matches)") {
		t.Fatal("empty list lost its no-matches hint")
	}
	long := make([]string, 40)
	for i := range long {
		long[i] = string(rune('a' + i%26))
	}
	windowed := PanelFixed(theme, "Model", long, 39, 40, 30, 9)
	if !rowHas(windowed, "→ n") {
		t.Fatal("selection at the list tail is not visible in the window")
	}
}

func rowHas(rows []string, text string) bool {
	for _, row := range rows {
		if strings.Contains(ansi.Strip(row), text) {
			return true
		}
	}
	return false
}
