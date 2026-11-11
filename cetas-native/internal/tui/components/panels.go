package components

import (
	"fmt"
	"strings"
	"sync"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type AskKind string

const (
	AskInput              AskKind = "input"
	AskSelect             AskKind = "select"
	AskConfirm            AskKind = "confirm"
	AskSecret             AskKind = "secret"
	PlanReviewTitlePrefix         = "Plan awaiting approval:"
)

// Geometry kept in step with cetas-js/ui/extension-ui.ts.
const (
	askPreviewLines  = 15
	askMaxOptions    = 8
	askBodyCacheSize = 4
)

type AskRequest struct {
	Kind                       AskKind
	Prompt, Title, Placeholder string
	Options                    []string
	DefaultYes                 bool
	DefaultIndex               int
}

// Renders the inline ask panel above the editor. The first title line is the
// bold question, the rest is the body (Markdown for selects, muted plain text
// otherwise); a select body longer than askPreviewLines collapses to a preview
// that ctrl+o expands, and options become either one button row or an
// askMaxOptions window.
//
// Every rendered line is sanitized, so a tool argument cannot move the cursor
// and a secret cannot smuggle a newline. An out-of-range selection renders no
// highlight.
func Ask(t Theme, r AskRequest, width, selected int, value string, expanded bool) []string {
	if width <= 0 {
		return nil
	}
	title := r.Title
	if title == "" {
		title = r.Prompt
	}
	head, rest, _ := strings.Cut(title, "\n")
	// Plan review is selector-only: the transcript already printed the plan.
	if r.Kind == AskSelect && strings.HasPrefix(title, PlanReviewTitlePrefix) {
		rest = ""
	}
	out := []string{}
	if strings.TrimSpace(head) != "" {
		for _, line := range askBody(head, width, askHeadBody) {
			out = append(out, Pad(lipgloss.NewStyle().Bold(true).Render(line.text), width))
		}
	}
	collapsible := false
	if strings.TrimSpace(rest) != "" {
		if r.Kind == AskSelect {
			body := askBody(rest, width, askMarkdownBody)
			shown := len(body)
			if len(body) > askPreviewLines {
				collapsible = true
				if !expanded {
					shown = askPreviewLines
				}
			}
			out = append(out, renderAskBody(t, body[:shown], width)...)
			if collapsible && !expanded {
				label := fmt.Sprintf("… (+%d lines, ctrl+o to expand)", len(body)-askPreviewLines)
				out = append(out, t.Role("muted", askCut(label, width)))
			}
		} else {
			out = append(out, renderAskBody(t, askBody(rest, width, askPlainBody), width)...)
		}
	}
	if r.Kind == AskInput || r.Kind == AskSecret {
		if r.Placeholder != "" {
			out = append(out, t.Role("muted", askClip(Clean(r.Placeholder), width)))
		}
		if r.Kind == AskSecret {
			value = strings.Repeat("•", len([]rune(value)))
		}
		out = append(out, Pad("> "+Clean(value), width), askCut(" ⏎ submit · esc cancel", width))
		return out
	}
	options := r.Options
	if r.Kind == AskConfirm {
		options = []string{"Yes", "No"}
	}
	labels := make([]string, len(options))
	for i, option := range options {
		labels[i] = Clean(option)
	}
	sel := selected
	if sel < 0 || sel >= len(labels) {
		sel = -1
	}
	horizontal := ansi.StringWidth(" "+strings.Join(labels, "   ")+" ") <= width
	if horizontal {
		buttons := make([]string, len(labels))
		for i, label := range labels {
			buttons[i] = t.Role("muted", " "+label+" ")
			if i == sel {
				buttons[i] = askSelectionStyle().Render(" " + label + " ")
			}
		}
		out = append(out, strings.Join(buttons, " "))
	} else {
		start, end := askVisibleRange(len(labels), sel)
		for i := start; i < end; i++ {
			if i == sel {
				// Truncate before padding, or a full-width label leaks past the
				// leading space.
				out = append(out, askSelectionStyle().Render(Pad(askClip(" "+labels[i], width), width)))
				continue
			}
			out = append(out, t.Role("muted", askClip(labels[i], width)))
		}
		if len(labels) > askMaxOptions && sel >= 0 {
			out = append(out, t.Role("muted", askCut(fmt.Sprintf(" (%d/%d)", sel+1, len(labels)), width)))
		}
	}
	direction := "←→"
	if !horizontal {
		direction = "↑↓"
	}
	hint := " " + direction + " choose · ⏎ confirm · esc cancel"
	if collapsible {
		if expanded {
			hint += " · ctrl+o collapse"
		} else {
			hint += " · ctrl+o expand"
		}
	}
	out = append(out, askCut(hint, width))
	return out
}

func askSelectionStyle() lipgloss.Style {
	return lipgloss.NewStyle().Bold(true).Background(lipgloss.Color("6")).Foreground(lipgloss.Color("0"))
}

// Keeps the selection centred without scrolling past either end.
func askVisibleRange(count, selected int) (int, int) {
	if count <= askMaxOptions {
		return 0, count
	}
	start := max(0, selected-askMaxOptions/2)
	end := min(count, start+askMaxOptions)
	start = max(0, end-askMaxOptions)
	return start, end
}

// truncateToWidth with the default ellipsis.
func askClip(s string, width int) string { return ansi.Truncate(s, width, "...") }

// truncateToWidth with no ellipsis.
func askCut(s string, width int) string { return ansi.Truncate(s, width, "") }

type askLineKind uint8

const (
	askPlain askLineKind = iota
	askBlank
	askHeadingLine
	askBullet
	askCode
	askMuted
)

// Unstyled: padding and theme roles are applied per render, so a cached body
// stays theme independent.
type askLine struct {
	text string
	kind askLineKind
}

type askBodyMode uint8

const (
	askMarkdownBody askBodyMode = iota
	askPlainBody
	askHeadBody
)

// Cheap fields first: comparing the text is a memcmp of the whole body.
type askBodyKey struct {
	width int
	mode  askBodyMode
	text  string
}

type askBodyEntry struct {
	key   askBodyKey
	lines []askLine
}

// Wrapping a long prompt is linear in its size and the panel renders every
// frame. Deliberately tiny, and it caches unstyled lines so a theme change
// cannot read a stale entry.
var askBodies struct {
	sync.Mutex
	entries []askBodyEntry
	renders int
}

// The returned slice is shared with the cache and must not be mutated.
func askBody(text string, width int, mode askBodyMode) []askLine {
	key := askBodyKey{width: width, mode: mode, text: text}
	askBodies.Lock()
	for i, entry := range askBodies.entries {
		if entry.key == key {
			lines := entry.lines
			copy(askBodies.entries[i:], askBodies.entries[i+1:])
			askBodies.entries[len(askBodies.entries)-1] = entry
			askBodies.Unlock()
			return lines
		}
	}
	askBodies.Unlock()
	lines := renderAskBodyText(askSanitize(text), width, mode)
	askBodies.Lock()
	askBodies.renders++
	entry := askBodyEntry{key: key, lines: lines}
	const byteBudget = 4 << 20
	cost := func(e askBodyEntry) int {
		n := len(e.key.text) + len(e.lines)*32
		for _, line := range e.lines {
			n += len(line.text)
		}
		return n
	}
	used := cost(entry)
	if used <= byteBudget {
		for _, old := range askBodies.entries {
			used += cost(old)
		}
		for len(askBodies.entries) > 0 && (len(askBodies.entries) >= askBodyCacheSize || used > byteBudget) {
			used -= cost(askBodies.entries[0])
			copy(askBodies.entries, askBodies.entries[1:])
			askBodies.entries[len(askBodies.entries)-1] = askBodyEntry{}
			askBodies.entries = askBodies.entries[:len(askBodies.entries)-1]
		}
		// Detach from the source string so the byte budget also bounds what it
		// retains.
		entry.key.text = strings.Clone(entry.key.text)
		askBodies.entries = append(askBodies.entries, entry)
	}
	askBodies.Unlock()
	return lines
}

// Clean per line: Clean folds control characters, the body's own newlines
// included, into spaces.
func askSanitize(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, line := range lines {
		lines[i] = Clean(line)
	}
	return strings.Join(lines, "\n")
}

// Markdown mode renders the block subset an ask body uses (paragraphs,
// headings, rules, lists, fenced code); anything else — tables, quotes, links —
// stays visible as its own text, so a body is never silently dropped. The plain
// and head modes keep the source line breaks.
func renderAskBodyText(src string, width int, mode askBodyMode) []askLine {
	src = strings.ReplaceAll(strings.ReplaceAll(src, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(src, "\n")
	out := make([]askLine, 0, len(lines))
	if mode != askMarkdownBody {
		kind := askMuted
		if mode == askHeadBody {
			kind = askPlain
		}
		for _, line := range lines {
			for _, wrapped := range wrapAsk(line, width) {
				out = append(out, askLine{text: wrapped, kind: kind})
			}
		}
		return out
	}
	// Block elements are separated by a blank line; a source blank line already
	// does that.
	separate := false
	add := func(kind askLineKind, marker, text string) {
		if separate && len(out) > 0 && out[len(out)-1].kind != askBlank {
			out = append(out, askLine{kind: askBlank})
		}
		separate = false
		indent := strings.Repeat(" ", ansi.StringWidth(marker))
		avail := max(1, width-ansi.StringWidth(marker))
		for i, wrapped := range wrapAsk(text, avail) {
			if i == 0 {
				out = append(out, askLine{text: marker + wrapped, kind: kind})
				continue
			}
			out = append(out, askLine{text: indent + wrapped, kind: kind})
		}
	}
	fence := ""
	// Markdown nests a list four spaces per depth, whatever the source indent
	// was; the stack tracks the open item indents.
	indents := []int{}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if fence != "" {
			if strings.HasPrefix(trimmed, fence) {
				add(askCode, "", "```")
				fence = ""
				separate = true
				continue
			}
			add(askCode, "  ", trimmed)
			continue
		}
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			indents = indents[:0]
			if len(out) > 0 && out[len(out)-1].kind != askBlank {
				separate = true
			}
			add(askCode, "", "```")
			fence = trimmed[:3]
			continue
		}
		if trimmed == "" {
			// Markdown collapses a run of blank lines into one separator.
			if len(out) == 0 || out[len(out)-1].kind != askBlank {
				out = append(out, askLine{kind: askBlank})
			}
			separate = false
			continue
		}
		if askRule(trimmed) {
			indents = indents[:0]
			if len(out) > 0 && out[len(out)-1].kind != askBlank {
				separate = true
			}
			add(askCode, "", strings.Repeat("─", max(1, width)))
			separate = true
			continue
		}
		if heading, ok := askHeading(trimmed); ok {
			indents = indents[:0]
			if len(out) > 0 && out[len(out)-1].kind != askBlank {
				separate = true
			}
			add(askHeadingLine, "", askInline(heading))
			separate = true
			continue
		}
		if indent, marker, item, ok := askListItem(line); ok {
			for len(indents) > 0 && len(indent) < indents[len(indents)-1] {
				indents = indents[:len(indents)-1]
			}
			if len(indents) == 0 || len(indent) > indents[len(indents)-1] {
				indents = append(indents, len(indent))
			}
			add(askBullet, strings.Repeat("    ", len(indents)-1)+marker, askInline(item))
			continue
		}
		indents = indents[:0]
		add(askPlain, "", askInline(strings.TrimRight(line, " ")))
	}
	if fence != "" {
		add(askCode, "", "```")
	}
	return out
}

func askRule(line string) bool {
	if len(line) < 3 {
		return false
	}
	c := line[0]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	for i := 0; i < len(line); i++ {
		if line[i] != c {
			return false
		}
	}
	return true
}

func askHeading(line string) (string, bool) {
	depth := 0
	for depth < len(line) && depth < 6 && line[depth] == '#' {
		depth++
	}
	if depth == 0 || depth >= len(line) || line[depth] != ' ' {
		return "", false
	}
	return strings.TrimSpace(strings.TrimRight(strings.TrimSpace(line[depth:]), "#")), true
}

// Splits an item into indent, marker and text. Ordered markers keep their
// source number instead of renumbering.
func askListItem(line string) (indent, marker, text string, ok bool) {
	i := 0
	for i < len(line) && line[i] == ' ' {
		i++
	}
	indent, rest := line[:i], line[i:]
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ' {
		return indent, "- ", strings.TrimLeft(rest[2:], " "), true
	}
	j := 0
	for j < len(rest) && j < 9 && rest[j] >= '0' && rest[j] <= '9' {
		j++
	}
	if j > 0 && j+1 < len(rest) && (rest[j] == '.' || rest[j] == ')') && rest[j+1] == ' ' {
		return indent, rest[:j+1] + " ", strings.TrimLeft(rest[j+2:], " "), true
	}
	return "", "", "", false
}

// Drops emphasis and code markers. Unmatched markers stay literal, and an
// underscore inside a word is never emphasis.
func askInline(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		if c == '`' {
			if j := strings.IndexByte(s[i+1:], '`'); j > 0 {
				b.WriteString(s[i+1 : i+1+j])
				i += j + 2
				continue
			}
		}
		if c == '*' || c == '_' {
			marker := string(c)
			if i+1 < len(s) && s[i+1] == c {
				marker = string([]byte{c, c})
			}
			opens := c != '_' || i == 0 || !isWordByte(s[i-1])
			if opens {
				if j := strings.Index(s[i+len(marker):], marker); j > 0 {
					inner := s[i+len(marker) : i+len(marker)+j]
					closes := c != '_' || i+len(marker)+j+1 >= len(s) || !isWordByte(s[i+len(marker)+j+1])
					if closes && strings.TrimSpace(inner) == inner {
						b.WriteString(inner)
						i += len(marker) + j + len(marker)
						continue
					}
				}
			}
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}

func isWordByte(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

func renderAskBody(t Theme, lines []askLine, width int) []string {
	out := make([]string, len(lines))
	for i, line := range lines {
		switch line.kind {
		case askBlank:
			out[i] = Pad("", width)
		case askHeadingLine:
			out[i] = Pad(t.Role("accent", lipgloss.NewStyle().Bold(true).Render(line.text)), width)
		case askBullet:
			out[i] = Pad(askBulletMarker(t, line.text), width)
		case askCode, askMuted:
			out[i] = Pad(t.Role("muted", line.text), width)
		default:
			out[i] = Pad(line.text, width)
		}
	}
	return out
}

func askBulletMarker(t Theme, line string) string {
	start := 0
	for start < len(line) && line[start] == ' ' {
		start++
	}
	end := start
	if end < len(line) && (line[end] == '-' || line[end] == '*' || line[end] == '+') {
		end++
	} else {
		for end < len(line) && line[end] >= '0' && line[end] <= '9' {
			end++
		}
		if end > start && end < len(line) && (line[end] == '.' || line[end] == ')') {
			end++
		} else {
			return line
		}
	}
	if end >= len(line) || line[end] != ' ' {
		return line
	}
	return t.Role("accent", line[:end]) + line[end:]
}

// CJK graphemes are break opportunities of their own, whitespace never starts a
// line, and a token wider than the panel breaks by grapheme.
func wrapAsk(s string, width int) []string {
	width = max(1, width)
	out := []string{}
	for _, line := range strings.Split(s, "\n") {
		out = append(out, wrapAskLine(line, width)...)
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

func wrapAskLine(line string, width int) []string {
	if ansi.StringWidth(line) <= width {
		return []string{line}
	}
	out := []string{}
	cur := ""
	curWidth := 0
	flush := func() {
		out = append(out, strings.TrimRight(cur, " "))
		cur, curWidth = "", 0
	}
	for _, token := range askTokens(line) {
		tokenWidth := ansi.StringWidth(token)
		if strings.TrimSpace(token) == "" {
			if curWidth == 0 {
				continue
			}
			if curWidth+tokenWidth > width {
				flush()
				continue
			}
			cur += token
			curWidth += tokenWidth
			continue
		}
		if tokenWidth > width {
			if curWidth > 0 {
				flush()
			}
			for _, cluster := range askClusters(token) {
				clusterWidth := ansi.StringWidth(cluster)
				if curWidth > 0 && curWidth+clusterWidth > width {
					flush()
				}
				cur += cluster
				curWidth += clusterWidth
			}
			continue
		}
		if curWidth > 0 && curWidth+tokenWidth > width {
			flush()
		}
		cur += token
		curWidth += tokenWidth
	}
	if cur != "" {
		flush()
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// Mirrors pi-tui's token split: whitespace runs, single CJK graphemes,
// everything else.
func askTokens(line string) []string {
	tokens := []string{}
	var word strings.Builder
	flush := func() {
		if word.Len() > 0 {
			tokens = append(tokens, word.String())
			word.Reset()
		}
	}
	for _, cluster := range askClusters(line) {
		switch {
		case strings.TrimSpace(cluster) == "":
			flush()
			if n := len(tokens); n > 0 && strings.TrimSpace(tokens[n-1]) == "" {
				tokens[n-1] += cluster
				continue
			}
			tokens = append(tokens, cluster)
		case askBreakCluster(cluster):
			flush()
			tokens = append(tokens, cluster)
		default:
			word.WriteString(cluster)
		}
	}
	flush()
	return tokens
}

// Grapheme clusters, so a wide character or emoji counts as one unit.
func askClusters(s string) []string {
	out := make([]string, 0, len(s))
	for len(s) > 0 {
		cluster, _ := ansi.FirstGraphemeCluster([]byte(s), ansi.GraphemeWidth)
		if len(cluster) == 0 {
			out = append(out, s)
			break
		}
		out = append(out, string(cluster))
		s = s[len(cluster):]
	}
	return out
}

// Scripts pi-tui treats as their own wrap token.
func askBreakCluster(cluster string) bool {
	for _, r := range cluster {
		return unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul, unicode.Bopomofo)
	}
	return false
}

// Dims the base and composites a centred bounded modal by display columns, so
// ANSI from the base cannot cancel the veil midway.
func ComposeOverlay(t Theme, base, panel []string, width, height int) []string {
	out := make([]string, max(0, height))
	for i := range out {
		s := ""
		if i < len(base) {
			s = ansi.Strip(base[i])
		}
		out[i] = t.Role("muted", lipgloss.NewStyle().Faint(true).Render(Pad(s, width)))
	}
	if width <= 0 || height <= 0 {
		return out
	}
	pw := 0
	for _, line := range panel {
		pw = max(pw, ansi.StringWidth(line))
	}
	pw = min(width, pw)
	ph := min(height, len(panel))
	left, top := max(0, (width-pw)/2), max(0, (height-ph)/2)
	for i := 0; i < ph; i++ {
		row := out[top+i]
		out[top+i] = ansi.Cut(row, 0, left) + Pad(panel[i], pw) + ansi.Cut(row, left+pw, width)
	}
	return out
}

// The item pane is exactly `rows` lines, so the box never resizes or recentres
// while the list changes under tabs or search.
func PanelFixed(t Theme, title string, items []string, selected, width, height, rows int) []string {
	width = max(1, width)
	height = max(1, height)
	if width < 4 || height < 3 {
		return Bound([]string{title}, width, height)
	}
	rows = min(max(0, rows), height-4)
	inner := width - 4
	out := []string{t.Role("muted", "╭"+strings.Repeat("─", width-2)+"╮"), "│ " + Pad(t.Role("brand", title), inner) + " │"}
	painted := 0
	if len(items) == 0 && rows > 0 {
		out = append(out, "│ "+Pad(t.Role("muted", "(no matches)"), inner)+" │")
		painted++
	}
	start := max(0, min(selected, len(items)-1)-rows/2)
	if start+rows > len(items) {
		start = max(0, len(items)-rows)
	}
	for i := start; i < len(items) && painted < rows; i++ {
		line := "  " + Clean(items[i])
		if i == selected {
			line = "→ " + Clean(items[i])
			line = t.Role("accent", line)
		}
		out = append(out, "│ "+Pad(line, inner)+" │")
		painted++
	}
	for ; painted < rows; painted++ {
		out = append(out, "│ "+Pad("", inner)+" │")
	}
	out = append(out, "│ "+Pad(t.Role("muted", "↑↓ choose · ⏎ confirm · esc cancel"), inner)+" │", t.Role("muted", "╰"+strings.Repeat("─", width-2)+"╯"))
	return out
}

func Panel(t Theme, title string, items []string, selected, width, height int) []string {
	width = max(1, width)
	height = max(1, height)
	if width < 4 || height < 3 {
		return Bound([]string{title}, width, height)
	}
	inner := width - 4
	out := []string{t.Role("muted", "╭"+strings.Repeat("─", width-2)+"╮"), "│ " + Pad(t.Role("brand", title), inner) + " │"}
	limit := max(0, height-4)
	start := max(0, selected-limit/2)
	if start+limit > len(items) {
		start = max(0, len(items)-limit)
	}
	for i := start; i < len(items) && i < start+limit; i++ {
		line := "  " + Clean(items[i])
		if i == selected {
			line = "→ " + Clean(items[i])
			line = t.Role("accent", line)
		}
		out = append(out, "│ "+Pad(line, inner)+" │")
	}
	out = append(out, "│ "+Pad(t.Role("muted", "↑↓ choose · ⏎ confirm · esc cancel"), inner)+" │", t.Role("muted", "╰"+strings.Repeat("─", width-2)+"╯"))
	return out
}
