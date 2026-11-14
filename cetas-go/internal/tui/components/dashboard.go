package components

import (
	"charm.land/lipgloss/v2"
	"encoding/json"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"math"
	"strings"
	"unicode"
)

type DashboardEntry struct {
	Key   string `json:"key"`
	Value string `json:"value"`
	Color string `json:"color,omitempty"`
	// colorSet records whether the JSON payload carried a `color` key. JS
	// distinguishes an omitted color (model emphasis) from an explicit empty
	// role (identity), which a bare string cannot express.
	colorSet bool
}

// UnmarshalJSON keeps the "color present but empty" distinction that JS
// `entry.color !== undefined` relies on. A struct literal can still set the
// non-empty Color directly; only JSON round-trips carry the empty case.
func (e *DashboardEntry) UnmarshalJSON(data []byte) error {
	var raw struct {
		Key   string  `json:"key"`
		Value string  `json:"value"`
		Color *string `json:"color"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	e.Key, e.Value, e.Color, e.colorSet = raw.Key, raw.Value, "", false
	if raw.Color != nil {
		e.Color, e.colorSet = *raw.Color, true
	}
	return nil
}

func (e DashboardEntry) hasColor() bool { return e.colorSet || e.Color != "" }

type DashboardContext struct {
	Branch, ContextValue                                string
	ActiveAgents, AwaitingReplies, PendingUserQuestions int
}
type ContextState struct {
	Source               string `json:"source"`
	WindowTokens         *int64 `json:"window_tokens"`
	LastMeasuredTokens   *int64 `json:"last_measured_tokens"`
	EstimatedAddedTokens *int64 `json:"estimated_added_tokens"`
}

func ContextOccupancy(s ContextState) (string, bool) {
	if s.Source != "measured" && s.Source != "estimated" && s.Source != "unknown" {
		return "", false
	}
	format := func(n int64) string {
		if n >= 1000000 {
			return fmt.Sprintf("%.1fM", math.Round(float64(n)/100000)/10)
		}
		if n >= 1000 {
			return fmt.Sprintf("%.1fK", math.Round(float64(n)/100)/10)
		}
		return fmt.Sprint(n)
	}
	known := s.Source != "unknown" && s.LastMeasuredTokens != nil && s.EstimatedAddedTokens != nil && *s.LastMeasuredTokens >= 0 && *s.EstimatedAddedTokens >= 0
	used := int64(0)
	value := "?"
	if known {
		used = *s.LastMeasuredTokens + *s.EstimatedAddedTokens
		value = format(used)
		if s.Source == "estimated" || *s.EstimatedAddedTokens > 0 {
			value = "~" + value
		}
	}
	if s.WindowTokens != nil && *s.WindowTokens > 0 {
		value += "/" + format(*s.WindowTokens)
		if known {
			value += fmt.Sprintf(" · %d%%", int(math.Floor(float64(used)*100/float64(*s.WindowTokens))))
		}
	}
	return value, true
}

// dashboardClean is the dashboard-local JS clean(): strip safe ANSI first,
// replace control bytes with spaces, then collapse every whitespace run and
// trim. The shared Clean helper keeps its own semantics for other packages.
func dashboardClean(s string) string {
	mapped := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, ansi.Strip(s))
	return strings.Join(strings.Fields(mapped), " ")
}

func Dashboard(t Theme, entries []DashboardEntry, width int, ctx DashboardContext) []string {
	if width <= 0 {
		return nil
	}
	get := func(key string) *DashboardEntry {
		for i := range entries {
			if strings.EqualFold(entries[i].Key, key) {
				return &entries[i]
			}
		}
		return nil
	}
	value := func(e *DashboardEntry) string {
		if e == nil {
			return ""
		}
		s := dashboardClean(e.Value)
		if rest, ok := strings.CutPrefix(s, e.Key+":"); ok {
			s = strings.TrimSpace(rest)
		}
		return s
	}
	segment := func(e *DashboardEntry, label bool) string {
		if e == nil {
			return ""
		}
		v := t.Role(e.Color, value(e))
		if label {
			return t.Role("muted", dashboardClean(e.Key)+" ") + v
		}
		return v
	}
	model := get("model")
	rawModel := ""
	if model != nil {
		// "model" is opaque (model name + effort): never strip its key.
		rawModel = dashboardClean(model.Value)
	}
	slot := ""
	if e := get("model_slot"); e != nil {
		// The slot is opaque too: a payload that itself starts with
		// "model_slot:" keeps that prefix, exactly like JS clean(value).
		slot = dashboardClean(e.Value)
	}
	displayModel := rawModel
	if slot != "" {
		displayModel = slot
		if at := strings.LastIndex(rawModel, ":"); at >= 0 {
			displayModel += rawModel[at:]
		}
	}
	modelValue := t.Role("muted", "No model")
	if displayModel != "" {
		if model != nil && model.hasColor() {
			modelValue = t.Role(model.Color, displayModel)
		} else {
			modelValue = lipgloss.NewStyle().Bold(true).Render(displayModel)
		}
	}
	header := " " + modelValue
	sep := t.Role("muted", " · ")
	if capability := segment(get("mcp"), false); capability != "" {
		header += sep + capability
	}
	if manager := segment(get("manager"), false); manager != "" {
		header += sep + manager
	}
	if branch := dashboardClean(ctx.Branch); branch != "" {
		header += " " + t.Role("muted", "⑂ ") + branchStyle(branch)
	}
	context := ctx.ContextValue
	if e := get("ctx"); e != nil {
		context = segment(e, false)
	}
	postpone := false
	if context != "" {
		postpone = ansi.StringWidth(header+sep+context) > width
		if !postpone {
			header += sep + context
		}
	}
	fields := []string{}
	if e := get("permission"); e != nil {
		fields = append(fields, segment(e, false))
	}
	if postpone {
		fields = append(fields, context)
	}
	quota, others := []string{}, []string{}
	for i, e := range entries {
		name := strings.ToLower(e.Key)
		switch name {
		case "model", "model_slot", "mcp", "ctx", "manager", "router", "status", "permission":
			continue
		}
		text := segment(&entries[i], true)
		if strings.Contains(name, "reset") {
			text = t.Role("warning", "Reset ") + segment(&entries[i], false)
		}
		switch name {
		case "5h", "7d", "weekly", "monthly", "quota", "time_limit", "remaining", "usage":
			quota = append(quota, text)
		default:
			others = append(others, text)
		}
	}
	fields = append(fields, quota...)
	if ctx.ActiveAgents > 0 || ctx.AwaitingReplies > 0 {
		word := "agents"
		if ctx.ActiveAgents == 1 {
			word = "agent"
		}
		activity := fmt.Sprintf("%d %s", ctx.ActiveAgents, word)
		if ctx.AwaitingReplies > 0 {
			activity += fmt.Sprintf(" · %d awaiting reply", ctx.AwaitingReplies)
		}
		fields = append(fields, t.Role("muted", activity))
	}
	if ctx.PendingUserQuestions > 0 {
		fields = append(fields, t.Role("warning", fmt.Sprintf("? %d to answer", ctx.PendingUserQuestions)))
	}
	fields = append(fields, others...)
	out := []string{Fit(header, width)}
	if len(fields) == 0 {
		return out
	}
	maxRows := 2
	if width < 28 {
		maxRows = 6
	} else if width < 70 {
		maxRows = 4
	}
	detail := wrapFields(t, fields, width-1, maxRows)
	for _, line := range detail {
		out = append(out, " "+line)
	}
	return out
}
func wrapFields(t Theme, fields []string, width, maxRows int) []string {
	if width <= 0 || maxRows <= 0 {
		return nil
	}
	lines := []string{}
	current := ""
	used := 0
	for _, field := range fields {
		if len(lines) >= maxRows {
			break
		}
		part := Fit(field, width-btoi(width > 8))
		next := part
		if current != "" {
			next = current + t.Role("muted", " · ") + part
		}
		if current != "" && ansi.StringWidth(next) > width {
			lines = append(lines, current)
			current = part
			if len(lines) >= maxRows {
				break
			}
		} else {
			current = next
		}
		used++
	}
	if len(lines) < maxRows && current != "" {
		lines = append(lines, current)
	}
	if used < len(fields) && len(lines) > 0 {
		notice := fmt.Sprintf("+%d more · /statusbar", len(fields)-used)
		last := len(lines) - 1
		if ansi.StringWidth(lines[last]+" · "+notice) <= width {
			lines[last] += t.Role("muted", " · ") + t.Role("muted", notice)
		} else {
			lines[last] = Fit(t.Role("muted", notice), width)
		}
	}
	return lines
}

// branchStyle is the dedicated branch colour from the JS dashboard
// (chalk.hex("#9BE1A1")); it is deliberately not the semantic success role.
func branchStyle(text string) string {
	return lipgloss.NewStyle().Foreground(lipgloss.Color("#9BE1A1")).Render(text)
}
func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}
