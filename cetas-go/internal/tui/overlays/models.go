// Package overlays contains interactive selector state without runtime access.
package overlays

import (
	"strings"
	"unicode/utf8"
)

// maxQueryRunes bounds the fuzzy search query. A model query is a subsequence
// filter over a small catalog, so past this length it cannot narrow the list
// further; the cap keeps one keystroke, a misrouted escape sequence or a
// paste from growing state that every render then re-filters.
const maxQueryRunes = 64

type ModelSlot struct {
	ID            string   `json:"id"`
	Label         string   `json:"label"`
	Model         string   `json:"model"`
	Provider      string   `json:"provider"`
	Active        bool     `json:"active"`
	Efforts       []string `json:"efforts"`
	DefaultEffort string   `json:"default_effort"`
}
type ModelSelection struct{ ID, Effort string }
type Models struct {
	Slots      []ModelSlot
	Tabs       []string
	Tab, Index int
	Query      string
	cursors    map[int]int
	efforts    map[string]int
}

func NewModels(slots []ModelSlot) Models {
	p := Models{Slots: slots, Tabs: []string{"All"}, cursors: map[int]int{}, efforts: map[string]int{}}
	seen := map[string]bool{}
	for i, s := range slots {
		if s.Provider != "" && !seen[s.Provider] {
			p.Tabs = append(p.Tabs, s.Provider)
			seen[s.Provider] = true
		}
		for j, e := range s.Efforts {
			if e == s.DefaultEffort {
				p.efforts[s.ID] = j
			}
		}
		if s.Active {
			p.Index = i
		}
	}
	return p
}

// tabs defaults a zero-value picker to the single "All" tab NewModels builds,
// so no accessor has to special-case an empty picker.
func (p Models) tabs() []string {
	if len(p.Tabs) == 0 {
		return []string{"All"}
	}
	return p.Tabs
}

// tabIndex clamps Tab into the tab range: a picker restored from stale state
// must not index past its tabs.
func (p Models) tabIndex() int { return min(max(0, p.Tab), len(p.tabs())-1) }

// editable reports whether text is plain character data, mirroring the JS
// picker's isPrintable guard: no control bytes, no C1 range and no escape
// prefix may reach the query.
func editable(text string) bool {
	if text == "" || !utf8.ValidString(text) {
		return false
	}
	for _, r := range text {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return false
		}
	}
	return true
}

func fuzzy(text, query string) bool {
	text = strings.ToLower(text)
	for _, r := range strings.ToLower(query) {
		at := strings.IndexRune(text, r)
		if at < 0 {
			return false
		}
		text = text[at+len(string(r)):]
	}
	return true
}
func (p Models) Rows() []ModelSlot {
	rows := []ModelSlot{}
	tab := p.tabIndex()
	for _, s := range p.Slots {
		if p.Query != "" {
			if !fuzzy(s.Label+" "+s.Model+" "+s.Provider, p.Query) {
				continue
			}
		} else if tab > 0 && s.Provider != p.tabs()[tab] {
			continue
		}
		rows = append(rows, s)
	}
	return rows
}
func (p Models) Selection() *ModelSelection {
	rows := p.Rows()
	if p.Index < 0 || p.Index >= len(rows) {
		return nil
	}
	s := rows[p.Index]
	effort := ""
	if len(s.Efforts) > 0 {
		effort = s.Efforts[min(p.efforts[s.ID], len(s.Efforts)-1)]
	}
	return &ModelSelection{ID: s.ID, Effort: effort}
}
func (p Models) Labels() []string {
	rows := p.Rows()
	labels := make([]string, len(rows))
	for i, s := range rows {
		label := s.Label
		if label == "" {
			label = s.Model
		}
		if label == "" {
			label = s.ID
		}
		if s.Active {
			label = "● " + label
		}
		if i == p.Index && len(s.Efforts) > 0 {
			efforts := append([]string(nil), s.Efforts...)
			at := min(p.efforts[s.ID], len(efforts)-1)
			efforts[at] = "[" + efforts[at] + "]"
			label += "  " + strings.Join(efforts, " ")
		}
		labels[i] = label
	}
	return labels
}
func (p Models) Title() string {
	tabs := append([]string(nil), p.tabs()...)
	at := p.tabIndex()
	tabs[at] = "[" + tabs[at] + "]"
	title := "Model · " + strings.Join(tabs, "  ")
	if p.Query != "" {
		title = "Model · Search: " + p.Query
	}
	return title
}

// Key returns false only for keys the containing modal must handle (close /
// submit). Escape clears search before being delegated as a close action.
func (p *Models) Key(key, text string) bool {
	if p.cursors == nil {
		p.cursors = map[int]int{}
	}
	if p.efforts == nil {
		p.efforts = map[string]int{}
	}
	switch key {
	case "tab", "shift+tab":
		tabs := p.tabs()
		p.cursors[p.tabIndex()] = p.Index
		delta := 1
		if key == "shift+tab" {
			delta = -1
		}
		p.Tab = (p.tabIndex() + delta + len(tabs)) % len(tabs)
		p.Query = ""
		p.Index = p.cursors[p.Tab]
	case "up", "ctrl+p":
		p.Index = max(0, p.Index-1)
	case "down", "ctrl+n":
		p.Index = min(max(0, len(p.Rows())-1), p.Index+1)
	case "left", "right":
		rows := p.Rows()
		if p.Index < len(rows) && p.Index >= 0 {
			s := rows[p.Index]
			if len(s.Efforts) > 0 {
				delta := 1
				if key == "left" {
					delta = -1
				}
				p.efforts[s.ID] = (p.efforts[s.ID] + delta + len(s.Efforts)) % len(s.Efforts)
			}
		}
	case "esc":
		if p.Query == "" {
			return false
		}
		p.Query = ""
		p.Index = min(p.Index, max(0, len(p.Rows())-1))
	case "backspace":
		r := []rune(p.Query)
		if len(r) > 0 {
			p.Query = string(r[:len(r)-1])
			p.Index = 0
		}
	default:
		if text == "" {
			return false
		}
		// A key the picker owns is consumed even when it does not edit the
		// query, so a rejected byte never falls through to another handler.
		if !editable(text) || len([]rune(p.Query))+len([]rune(text)) > maxQueryRunes {
			return true
		}
		p.Query += text
		p.Index = 0
	}
	p.Index = min(p.Index, max(0, len(p.Rows())-1))
	return true
}
