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
