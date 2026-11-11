package tui

// While `switch_session` composes the target session there is no transcript to
// paint; these bars hold the eye and the row block steady.

import (
	"strings"

	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// Bar widths as a percentage of the available width: uneven runs read as a
// placeholder, a single full-width rule as a separator.
var switchSkeletonWidths = [...]int{60, 40, 75}

// Every line is padded to exactly width cells so the frame keeps its geometry
// while the transcript is empty.
func switchSkeletonLines(theme ui.Theme, width int) []string {
	if width <= 0 {
		return nil
	}
	lines := make([]string, 0, len(switchSkeletonWidths)+1)
	for _, share := range switchSkeletonWidths {
		bar := strings.Repeat("─", max(0, min(width-1, width*share/100)))
		lines = append(lines, ui.Pad(theme.Role("muted", bar), width))
	}
	return append(lines, ui.Pad(theme.Role("muted", " loading session…"), width))
}
