package tui

import (
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Inline images via the kitty graphics protocol's Unicode placeholders
// (kitty ≥0.28, Ghostty). One quiet-mode transmit (a=t,q=2,f=100 for PNG) under
// a stable id, one virtual placement (a=p,U=1,c=,r=) declaring the cell
// rectangle, then U+10EEEE cells carrying the id in the foreground color with
// the row number as digit diacritics on each row's first cell. Being plain
// text, placeholders scroll, cache and are overwritten like any other row — no
// placement bookkeeping against the renderer.

// The Private Use character the protocol renders image cells on.
const kittyPlaceholderCell = "\U0010EEEE"

// Digits 0-9 → combining characters (kitty's rowcolumn-diacritics table, first
// ten entries).
var kittyRowDiacritics = []rune{0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A}

// Bounds terminal memory; placeholders for an unknown id render as empty cells,
// never corruption.
const kittyMaxImages = 64

func kittySupported() bool {
	if os.Getenv("CETAS_NATIVE_DISABLE_IMAGE_DISPLAY") != "" {
		return false
	}
	if os.Getenv("GHOSTTY_RESOURCES_DIR") != "" || os.Getenv("KITTY_WINDOW_ID") != "" {
		return true
	}
	term := os.Getenv("TERM")
	return strings.Contains(term, "ghostty") || strings.HasPrefix(term, "xterm-kitty")
}

func kittyDiacritics(n int) string {
	if n < 0 {
		return ""
	}
	digits := strconv.Itoa(n)
	var b strings.Builder
	for _, d := range digits {
		b.WriteRune(kittyRowDiacritics[d-'0'])
	}
	return b.String()
}

func pngDimensions(data string) (width, height int, ok bool) {
	raw, err := base64.StdEncoding.DecodeString(data)
	if err != nil || len(raw) < 24 {
		return 0, 0, false
	}
	// Signature and length, then "IHDR", then big-endian width/height.
	if string(raw[12:16]) != "IHDR" {
		return 0, 0, false
	}
	return int(uint32(raw[16])<<24 | uint32(raw[17])<<16 | uint32(raw[18])<<8 | uint32(raw[19])),
		int(uint32(raw[20])<<24 | uint32(raw[21])<<16 | uint32(raw[22])<<8 | uint32(raw[23])),
		true
}

// Cell aspect is assumed 1:2 (w:h); rows are capped so one image never owns the
// screen.
func kittyCellLayout(imgWidth, imgHeight, availableCols int) (cols, rows int) {
	if imgWidth <= 0 || imgHeight <= 0 || availableCols < 4 {
		return 0, 0
	}
	cols = min(availableCols, max(8, imgWidth/12))
	rows = max(1, int(float64(cols)*(float64(imgHeight)/float64(imgWidth))/2.0+0.5))
	return cols, min(rows, 24)
}

func kittyTransmit(id int, base64Data string) string {
	var b strings.Builder
	first := true
	for start := 0; start < len(base64Data) || first; start += 4096 {
		end := min(start+4096, len(base64Data))
		last := end >= len(base64Data)
		if first {
			b.WriteString(fmt.Sprintf("\x1b_Ga=t,q=2,i=%d,f=100,m=%d;", id, boolDigit(!last)))
			first = false
		} else {
			b.WriteString(fmt.Sprintf("\x1b_Gm=%d;", boolDigit(!last)))
		}
		b.WriteString(base64Data[start:end])
		b.WriteString("\x1b\\")
		if last {
			break
		}
	}
	return b.String()
}

func boolDigit(b bool) int {
	if b {
		return 1
	}
	return 0
}

func kittyVirtualPlacement(id, cols, rows int) string {
	return fmt.Sprintf("\x1b_Ga=p,U=1,i=%d,c=%d,r=%d\x1b\\", id, cols, rows)
}

// Only each row's first cell carries row diacritics; the rest inherit row and
// column from the left neighbour per the protocol.
func kittyPlaceholderLines(id, cols, rows int) string {
	prefix := "\x1b[38;5;" + strconv.Itoa(id) + "m"
	suffix := "\x1b[39m"
	lines := make([]string, rows)
	for row := 0; row < rows; row++ {
		var b strings.Builder
		b.WriteString(prefix)
		b.WriteString(kittyPlaceholderCell)
		b.WriteString(kittyDiacritics(row))
		for col := 1; col < cols; col++ {
			b.WriteString(kittyPlaceholderCell)
		}
		b.WriteString(suffix)
		lines[row] = b.String()
	}
	return strings.Join(lines, "\n")
}

type kittyImageLayout struct {
	id        int
	cols      int
	rows      int
	fallback  string
	transmits string
}

// Fits an image inside a fixed cell box so a strip of thumbnails keeps a
// uniform height whatever the source image's shape.
func kittyThumbLayout(imgWidth, imgHeight, maxCols, maxRows int) (cols, rows int) {
	if imgWidth <= 0 || imgHeight <= 0 {
		return 0, 0
	}
	cols = maxCols
	rows = (cols*imgHeight + imgWidth - 1) / imgWidth
	if rows > maxRows {
		rows = maxRows
		cols = (rows*imgWidth + imgHeight - 1) / imgHeight
	}
	if cols < 1 || rows < 1 {
		return 0, 0
	}
	return cols, rows
}

func kittyDeleteImage(id int) string {
	return fmt.Sprintf("\x1b_Ga=d,i=%d\x1b\\", id)
}

// Tray thumbs live apart from the transcript registry: the same image is often
// both a tray chip and, after submit, a transcript block, and each presentation
// owns its geometry.
func (m *model) stageKittyThumb(attachment imageAttachment) (kittyImageLayout, bool) {
	if !kittySupported() || attachment.MediaType != "image/png" {
		return kittyImageLayout{}, false
	}
	imgWidth, imgHeight, ok := pngDimensions(attachment.Data)
	if !ok {
		return kittyImageLayout{}, false
	}
	cols, rows := kittyThumbLayout(imgWidth, imgHeight, trayThumbCols, trayThumbRows)
	if cols == 0 {
		return kittyImageLayout{}, false
	}
	if m.kittyThumbs == nil {
		m.kittyThumbs = map[string]kittyImageLayout{}
	}
	if existing, seen := m.kittyThumbs[attachment.Data]; seen {
		return existing, true
	}
	if len(m.kittyThumbs) >= kittyMaxImages {
		return kittyImageLayout{}, false
	}
	m.nextKittyID++
	id := m.nextKittyID
	layout := kittyImageLayout{
		id:        id,
		cols:      cols,
		rows:      rows,
		fallback:  attachment.Label,
		transmits: kittyTransmit(id, attachment.Data) + kittyVirtualPlacement(id, cols, rows),
	}
	m.kittyThumbs[attachment.Data] = layout
	return layout, true
}

// Unsupported terminals or non-PNG media degrade to the fallback chip line.
func (m *model) stageKittyImage(attachment imageAttachment, availableCols int) (kittyImageLayout, bool) {
	if !kittySupported() || attachment.MediaType != "image/png" {
		return kittyImageLayout{}, false
	}
	imgWidth, imgHeight, ok := pngDimensions(attachment.Data)
	if !ok {
		return kittyImageLayout{}, false
	}
	cols, rows := kittyCellLayout(imgWidth, imgHeight, availableCols)
	if cols == 0 {
		return kittyImageLayout{}, false
	}
	if m.kittyImages == nil {
		m.kittyImages = map[string]kittyImageLayout{}
	}
	if existing, seen := m.kittyImages[attachment.Data]; seen {
		return existing, true
	}
	if len(m.kittyImages) >= kittyMaxImages {
		return kittyImageLayout{}, false
	}
	m.nextKittyID++
	id := m.nextKittyID
	layout := kittyImageLayout{
		id:        id,
		cols:      cols,
		rows:      rows,
		fallback:  fmt.Sprintf("🖼 %s (%s)", attachment.Label, formatImageBytes(attachment.Bytes)),
		transmits: kittyTransmit(id, attachment.Data) + kittyVirtualPlacement(id, cols, rows),
	}
	m.kittyImages[attachment.Data] = layout
	return layout, true
}
