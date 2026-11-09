// Package components contains pure terminal presentation. It never imports the
// runtime harness, reads settings or obtains credentials.
package components

import (
	"image/color"
	"math"
	"strings"
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
func Fit(s string, width int) string {
	if width <= 0 {
		return ""
	}
	return ansi.Truncate(s, width, "…")
}
func Pad(s string, width int) string {
	s = Fit(s, width)
	return s + strings.Repeat(" ", max(0, width-ansi.StringWidth(s)))
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
