package tui

import (
	"strings"

	"github.com/colmugx/cetas/cetas-go/internal/tui/components"
)

// The tray docks staged images above the composer. On graphics terminals each
// chip is a live thumbnail using the transcript's unicode-placeholder
// technique; elsewhere it degrades to the text glyph line.
//
// One muted header, then a single 8×3 thumbnail band that never wraps.
func (m *model) attachmentTrayLines(theme components.Theme, w int) []string {
	if len(m.pendingImages) == 0 {
		return nil
	}
	muted := func(s string) string { return theme.Role("muted", s) }
	thumbs := make([]kittyImageLayout, 0, len(m.pendingImages))
	for _, staged := range m.pendingImages {
		if thumb, ok := m.kittyThumbs[staged.Data]; ok {
			thumbs = append(thumbs, thumb)
		}
	}
	if len(thumbs) != len(m.pendingImages) {
		summary := m.stagedImageSummary()
		return []string{muted(components.Fit(" "+summary, w))}
	}
	header := muted(components.Fit(
		" 🖼 "+pluralImages(len(thumbs))+" attached · Enter sends · Esc clears", w))
	rows := make([]string, 0, trayThumbRows+2)
	rows = append(rows, header)
	band := make([]string, trayThumbRows)
	for i := range m.pendingImages {
		thumb := thumbs[i]
		left := i * (trayThumbCols + 1)
		if left+thumb.cols > w {
			break
		}
		placeholder := strings.Split(kittyPlaceholderLines(thumb.id, thumb.cols, thumb.rows), "\n")
		for r := 0; r < trayThumbRows; r++ {
			cell := strings.Repeat(" ", thumb.cols)
			if r < len(placeholder) {
				cell = placeholder[r]
			}
			band[r] += strings.Repeat(" ", left-len(band[r])) + cell + " "
		}
	}
	for _, line := range band {
		rows = append(rows, components.Pad(line, w))
	}
	caption := ""
	for i, attachment := range m.pendingImages {
		if i > 0 {
			caption += " "
		}
		label := attachment.Label
		if len(label) > trayThumbCols+2 {
			label = label[:trayThumbCols+2] + "…"
		}
		caption += label + " " + theme.Role("muted", "("+formatImageBytes(attachment.Bytes)+")")
	}
	return append(rows, muted(components.Fit(" "+caption, w)))
}

func pluralImages(n int) string {
	if n == 1 {
		return "1 image"
	}
	return itoaInt(n) + " images"
}

func itoaInt(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
