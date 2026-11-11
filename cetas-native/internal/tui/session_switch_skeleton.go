package tui

// Session-switch skeleton: while `switch_session` composes the target session
// in the background there is no transcript to paint yet and the picker has
// already retired, so the only thing on screen used to be the bare
// "loading session…" status line. Three dim bars above that label hold the eye
// and the row block steady for the length of the switch.

import (
	"strings"

	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// switchSkeletonWidths are the bar widths as a percentage of the available
// width: three uneven runs read as a placeholder, a single full-width rule
// reads as a separator.
var switchSkeletonWidths = [...]int{60, 40, 75}

// switchSkeletonLines is the stand-in painted during a switch: one bar per
// switchSkeletonWidths entry over the loading label. Every line is padded to
// exactly width cells so the frame keeps its geometry while the transcript is
// empty. A bar never spans the whole width, and width <= 0 paints nothing.
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
