package tui

import (
	"strings"
	"testing"
)

func TestSlashSuggestionsPrefixAndFuzzy(t *testing.T) {
	matches := slashSuggestions("/mo")
	if len(matches) == 0 || matches[0].insert != "/model" {
		t.Fatalf("/mo must first suggest /model: %#v", matches)
	}
	matches = slashSuggestions("/ss")
	if len(matches) == 0 || matches[0].insert != "/sessions" {
		t.Fatalf("fuzzy /ss must find sessions: %#v", matches)
	}
	if len(slashSuggestions("hello /mo")) != 0 || len(slashSuggestions("/model foo")) != 0 {
		t.Fatal("completion must not rewrite prompts or arbitrary command arguments")
	}
}

func TestSlashSuggestionsPermissionArgs(t *testing.T) {
	matches := slashSuggestions("/permission work")
	if len(matches) != 1 || matches[0].insert != "/permission workspace_write" {
		t.Fatalf("mode completion: %#v", matches)
	}
	if len(slashSuggestions("/permission yolo next")) != 0 {
		t.Fatal("must not eat trailing command arguments")
	}
}

func TestSlashSuggestionInsertDoesNotExecute(t *testing.T) {
	if got := slashInsertion("/login"); got != "/login " {
		t.Fatalf("argument command insertion: %q", got)
	}
	if got := slashInsertion("/help"); got != "/help" {
		t.Fatalf("standalone command insertion: %q", got)
	}
	if got := slashInsertion("/permission workspace_write"); got != "/permission workspace_write" {
		t.Fatalf("argument choice insertion: %q", got)
	}
}

func TestSlashHelpMatchesRegistry(t *testing.T) {
	help := nativeSlashHelp()
	for _, command := range nativeSlashCommands {
		if !strings.Contains(help, command.name+" — ") {
			t.Fatalf("missing %s in help", command.name)
		}
	}
	// Questions now have a native event source and typed answer route. Pi
	// package management still has no native implementation and must stay out.
	if !strings.Contains(help, "/answer — ") || !strings.Contains(help, "/questions — ") {
		t.Fatal("native question commands missing from help")
	}
	if strings.Contains(help, "/pi — ") {
		t.Fatal("do not advertise unimplemented JS-only integrations")
	}
}
