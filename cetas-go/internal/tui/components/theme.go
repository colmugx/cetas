// Package components contains pure terminal presentation. It never imports the
// runtime harness, reads settings or obtains credentials.
package components

import (
	"image/color"
	"math"
	"strings"
	"sync"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type Theme struct{ FG, BG color.Color }

func NewTheme(fg, bg color.Color) Theme { return Theme{fg, bg} }
func luminance(c color.Color) float64 {
	r, g, b, _ := c.RGBA()
	f := func(v uint32) float64 {
		x := float64(v) / 65535
		if x <= .04045 {
			return x / 12.92
		}
		return math.Pow((x+.055)/1.055, 2.4)
	}
	return .2126*f(r) + .7152*f(g) + .0722*f(b)
}
func contrast(a, b color.Color) float64 {
	x, y := luminance(a), luminance(b)
	return (math.Max(x, y) + .05) / (math.Min(x, y) + .05)
}
func (t Theme) Color(role string) color.Color {
	palettes := map[string][2]string{"brand": {"#92CDB5", "#216B52"}, "accent": {"#55CDE9", "#006780"}, "warning": {"#FFD080", "#865700"}, "error": {"#FF7E83", "#A7202A"}, "success": {"#75D899", "#177039"}, "info": {"#7FB0FF", "#234C9A"}, "muted": {"#A0A0A0", "#565656"}}
	colors, ok := palettes[role]
	if !ok {
		return nil
	}
	variant := 0
	if t.BG != nil && luminance(t.BG) >= .179 {
		variant = 1
	}
	c := lipgloss.Color(colors[variant])
	if t.BG != nil && t.FG != nil && contrast(c, t.BG) < 4.5 {
		return t.FG
	}
	return c
}
func (t Theme) Role(role, text string) string {
	if c := t.Color(role); c != nil {
		return lipgloss.NewStyle().Foreground(c).Render(text)
	}
	return text
}
func (t Theme) Surface(kind, text string) string {
	if t.FG == nil || t.BG == nil {
		return text
	}
	tint := t.FG
	alpha := .11
	switch kind {
	case "user":
		// Deeper than the ambient surfaces: the user's message is the block to
		// find at a glance.
		alpha = .18
	case "pending":
		tint = color.RGBA{202, 156, 56, 255}
		alpha = .12
	case "error":
		tint = color.RGBA{212, 76, 76, 255}
		alpha = .12
	case "success":
		tint = color.RGBA{65, 173, 94, 255}
		alpha = .12
	}
	br, bg, bb, _ := t.BG.RGBA()
	tr, tg, tb, _ := tint.RGBA()
	mix := func(a, b uint32) uint8 { return uint8(math.Round((float64(a)*(1-alpha) + float64(b)*alpha) / 257)) }
	c := color.RGBA{mix(br, tr), mix(bg, tg), mix(bb, tb), 255}
	if contrast(t.FG, c) < 4.5 {
		return text
	}
	return lipgloss.NewStyle().Background(c).Render(text)
}
func Clean(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, ansi.Strip(s))
}

// Ingest filter for runtime-sourced text re-emitted to the terminal (tool
// results, summaries, diagnostics): printable text, tabs, newlines and SGR
// colors survive — colored tool output stays legible — and every other escape
// dies here, so OSC 8 spoofing, OSC 52 clipboard writes, kitty passthrough,
// title rewrites and screen clears from untrusted output cannot land. Locally
// generated styling is applied after ingest and is unaffected.
func SanitizeSGR(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\x1b':
			if i+1 >= len(s) {
				i++
				continue
			}
			switch next := s[i+1]; {
			case next == '[':
				// CSI: params/intermediates then one final byte; only SGR survives.
				j := i + 2
				for j < len(s) && s[j] >= 0x20 && s[j] <= 0x3f {
					j++
				}
				if j >= len(s) {
					i = len(s) // truncated run: drop it
					continue
				}
				if s[j] == 'm' {
					b.WriteString(s[i : j+1])
				}
				i = j + 1
			case next == ']' || next == 'P' || next == 'X' || next == '^' || next == '_':
				// String sequences (OSC/DCS/SOS/PM/APC) run to BEL or ST.
				j := i + 2
				for j < len(s) {
					if s[j] == '\x07' {
						j++
						break
					}
					if s[j] == '\x1b' && j+1 < len(s) && s[j+1] == '\\' {
						j += 2
						break
					}
					j++
				}
				i = j
			default:
				i += 2 // two-byte escape: dropped
			}
		case c == '\n' || c == '\t':
			b.WriteByte(c)
			i++
		case c < 0x20 || c == 0x7f:
			b.WriteByte(' ')
			i++
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}
func Fit(s string, width int) string {
	if width <= 0 {
		return ""
	}
	if w, ok := fastWidth(s); ok && w <= width {
		return s
	}
	if cachedWidth(s) <= width {
		return s
	}
	return ansi.Truncate(s, width, "…")
}

// fastWidth measures plain printable ASCII without a grapheme walk or a map
// probe; scrolling re-fits mostly ASCII transcript rows every frame.
func fastWidth(s string) (int, bool) {
	for i := 0; i < len(s); i++ {
		if s[i] <= 0x1f || s[i] >= 0x7f {
			return 0, false
		}
	}
	return len(s), true
}

// widthMemo caches display widths of recently measured lines: a hash hit costs
// roughly a tenth of a grapheme-cluster walk, and consecutive frames during a
// scroll re-present largely identical chrome and cached rows. The budget is in
// key bytes, not entries: a caller measuring a large string must not be able to
// park unbounded text here.
var widthMemo = struct {
	sync.Mutex
	entries map[string]int
	bytes   int
}{entries: map[string]int{}}

const widthMemoBytes = 64 << 10

func cachedWidth(s string) int { return CachedWidth(s) }

// CachedWidth is the shared display-width probe: printable ASCII short-circuits
// without a grapheme walk, everything else hits the bounded width memo.
func CachedWidth(s string) int {
	widthMemo.Lock()
	if w, ok := widthMemo.entries[s]; ok {
		widthMemo.Unlock()
		return w
	}
	widthMemo.Unlock()
	w := ansi.StringWidth(s)
	widthMemo.Lock()
	if widthMemo.bytes+len(s) > widthMemoBytes {
		// Scroll keeps re-touching the hot set, so dropping entries until
		// half the budget is free is enough to stay bounded.
		for key := range widthMemo.entries {
			if widthMemo.bytes <= widthMemoBytes/2 {
				break
			}
			widthMemo.bytes -= len(key)
			delete(widthMemo.entries, key)
		}
		if widthMemo.bytes+len(s) > widthMemoBytes {
			// One string larger than the whole budget is measured but never
			// retained.
			widthMemo.Unlock()
			return w
		}
	}
	widthMemo.entries[s] = w
	widthMemo.bytes += len(s)
	widthMemo.Unlock()
	return w
}

func Pad(s string, width int) string {
	s = Fit(s, width)
	return s + strings.Repeat(" ", max(0, width-cachedWidth(s)))
}
func Bound(lines []string, width, height int) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	out := make([]string, min(height, len(lines)))
	for i := range out {
		out[i] = Fit(lines[i], width)
	}
	return out
}
