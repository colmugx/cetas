package overlays

import (
	"strings"
	"testing"
)

func TestModelTabsKeepIndependentCursorAndAdvertisedEffort(t *testing.T) {
	p := NewModels([]ModelSlot{{ID: "a", Provider: "one", Label: "A", Efforts: []string{"low", "high"}}, {ID: "b", Provider: "one", Label: "B"}, {ID: "c", Provider: "two", Label: "C"}})
	p.Key("tab", "")
	p.Key("down", "")
	if s := p.Selection(); s == nil || s.ID != "b" || s.Effort != "" {
		t.Fatalf("no-effort model gained synthetic effort: %#v", s)
	}
	p.Key("tab", "")
	p.Key("shift+tab", "")
	if s := p.Selection(); s == nil || s.ID != "b" {
		t.Fatal("provider cursor not retained")
	}
	p.Key("up", "")
	p.Key("right", "")
	if s := p.Selection(); s == nil || s.ID != "a" || s.Effort != "high" {
		t.Fatalf("effort not selected: %#v", s)
	}
	p.Key("c", "C")
	if s := p.Selection(); s == nil || s.ID != "c" {
		t.Fatal("fuzzy query should search across tabs")
	}
	if !p.Key("esc", "") || p.Query != "" {
		t.Fatal("first Esc must clear query")
	}
	if p.Key("esc", "") {
		t.Fatal("second Esc is delegated to close modal")
	}
}

// A zero-value picker is reachable before the catalog arrives (the native
// model owns one), so every accessor must work without tabs, cursors or slots.
func TestModelZeroValueIsSafe(t *testing.T) {
	var p Models
	if rows := p.Rows(); len(rows) != 0 {
		t.Fatalf("zero-value rows: %#v", rows)
	}
	if p.Selection() != nil {
		t.Fatal("zero-value selection")
	}
	if labels := p.Labels(); len(labels) != 0 {
		t.Fatalf("zero-value labels: %#v", labels)
	}
	if title := p.Title(); !strings.Contains(title, "[All]") {
		t.Fatalf("zero-value title lost its default tab: %q", title)
	}
	for _, key := range []string{"tab", "shift+tab", "up", "down", "left", "right", "backspace"} {
		if !p.Key(key, "") {
			t.Fatalf("%q was delegated by an empty picker", key)
		}
	}
	if !p.Key("a", "a") || p.Query != "a" {
		t.Fatalf("zero-value search: %q", p.Query)
	}
	if !p.Key("esc", "") || p.Query != "" {
		t.Fatal("esc must clear the query first")
	}
	if p.Key("esc", "") {
		t.Fatal("esc without a query is delegated to close the modal")
	}
}

func TestModelTabIndexIsClampedInsteadOfPanicking(t *testing.T) {
	p := Models{Slots: []ModelSlot{{ID: "a", Provider: "one"}, {ID: "b", Provider: "two"}}, Tabs: []string{"All", "one", "two"}, Tab: 7}
	if rows := p.Rows(); len(rows) != 1 || rows[0].ID != "b" {
		t.Fatalf("clamped tab filtered wrong: %#v", rows)
	}
	if title := p.Title(); !strings.Contains(title, "[two]") {
		t.Fatalf("clamped title: %q", title)
	}
	p.Tab = -3
	if rows := p.Rows(); len(rows) != 2 {
		t.Fatalf("negative tab must read as All: %#v", rows)
	}
}

// The query is a fuzzy subsequence filter, not a text field: only printable
// character data may grow it, and it stops accepting characters once it is
// long enough that no catalog could narrow further. Nothing already typed is
// ever dropped, and no partial paste is inserted.
func TestModelQueryRejectsControlDataAndStopsGrowing(t *testing.T) {
	p := NewModels([]ModelSlot{{ID: "gpt-6", Label: "GPT-6", Provider: "openai"}})
	for _, hostile := range []string{"\x1b", "\x1b[31m", "\x00", "\x7f", "\x9b", "ok\x1b[0m"} {
		if !p.Key("x", hostile) {
			t.Fatalf("%q was delegated instead of consumed", hostile)
		}
		if p.Query != "" {
			t.Fatalf("%q reached the query: %q", hostile, p.Query)
		}
	}
	// A single oversized paste is rejected whole, never truncated into the
	// query.
	paste := strings.Repeat("z", maxQueryRunes*4)
	p.Key("z", paste)
	if p.Query != "" {
		t.Fatalf("oversized paste was partially inserted: %d runes", len([]rune(p.Query)))
	}
	// Individual keystrokes fill the query up to the cap and then stop.
	for i := 1; i <= maxQueryRunes+5; i++ {
		if !p.Key("q", "q") {
			t.Fatal("printable key delegated")
		}
		if want := strings.Repeat("q", min(i, maxQueryRunes)); p.Query != want {
			t.Fatalf("keystroke %d: query %q want %q", i, p.Query, want)
		}
	}
	if len([]rune(p.Query)) != maxQueryRunes {
		t.Fatalf("query is not bounded: %d runes", len([]rune(p.Query)))
	}
	// Backspace still edits the accepted query.
	p.Key("backspace", "")
	if len([]rune(p.Query)) != maxQueryRunes-1 {
		t.Fatalf("backspace did not edit: %d runes", len([]rune(p.Query)))
	}
}

func TestModelQueryStaysMultibyteSafe(t *testing.T) {
	p := NewModels([]ModelSlot{{ID: "a", Label: "模型", Provider: "one"}})
	p.Key("模", "模")
	if p.Query != "模" || len(p.Rows()) != 1 {
		t.Fatalf("CJK query: %q rows=%d", p.Query, len(p.Rows()))
	}
	p.Key("backspace", "")
	if p.Query != "" || len(p.Rows()) != 1 {
		t.Fatalf("CJK backspace: %q rows=%d", p.Query, len(p.Rows()))
	}
}
