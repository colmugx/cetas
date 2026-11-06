package main

import (
	"sort"
	"strings"
)

// Only commands implemented by the native Harness are advertised here. JS
// extension commands must not appear until a command registry is bridged.
type nativeSlashCommand struct {
	name        string
	description string
	acceptsArgs bool
}

var nativeSlashCommands = []nativeSlashCommand{
	{"/model", "Choose a model", false},
	{"/effort", "Select reasoning effort", true},
	{"/new", "Start a new session", false},
	{"/sessions", "Browse sessions", false},
	{"/rewind", "Restore an earlier prompt", false},
	{"/login", "Sign in to a provider", true},
	{"/logout", "Sign out of a provider", true},
	{"/permission", "Set the permission mode", true},
	{"/skills", "Browse installed skills", false},
	{"/compact", "Compact session context", false},
	{"/find", "Find transcript text across the full history", true},
	{"/find-next", "Jump to next transcript match", false},
	{"/find-prev", "Jump to previous transcript match", false},
	{"/copyhistory", "Copy source transcript entry range", true},
	{"/help", "Show available commands", false},
}

type slashSuggestion struct {
	label  string
	insert string
}

// slashSuggestions completes only a command name or a supported local argument
// list. It never starts a command: selecting an item only edits the prompt.
// More complex arguments (models, providers, extensions) require native
// capability snapshots, so we deliberately do not guess their values.
func slashSuggestions(text string) []slashSuggestion {
	if !strings.HasPrefix(text, "/") || strings.ContainsAny(text, "\n\r\t") {
		return nil
	}
	if strings.HasPrefix(text, "/permission ") {
		prefix := strings.ToLower(strings.TrimPrefix(text, "/permission "))
		if strings.Contains(prefix, " ") {
			return nil
		}
		var matches []slashSuggestion
		for _, mode := range []string{"readonly", "workspace_write", "interactive", "yolo"} {
			if strings.HasPrefix(mode, prefix) {
				matches = append(matches, slashSuggestion{label: mode, insert: "/permission " + mode})
			}
		}
		return matches
	}
	if strings.Contains(text, " ") {
		return nil
	}
	prefix := strings.ToLower(text)
	type ranked struct {
		value slashSuggestion
		score int
		order int
	}
	var found []ranked
	for order, command := range nativeSlashCommands {
		name := strings.ToLower(command.name)
		// Match prefixes first, then in-order subsequences (as in a compact
		// command palette). Unrelated commands are never suggested.
		score := 0
		if !strings.HasPrefix(name, prefix) {
			if !slashSubsequence(name, prefix) {
				continue
			}
			score = 1
		}
		found = append(found, ranked{
			value: slashSuggestion{label: command.name + " — " + command.description, insert: command.name},
			score: score, order: order,
		})
	}
	sort.SliceStable(found, func(i, j int) bool {
		if found[i].score != found[j].score {
			return found[i].score < found[j].score
		}
		return found[i].order < found[j].order
	})
	result := make([]slashSuggestion, 0, len(found))
	for _, suggestion := range found {
		result = append(result, suggestion.value)
	}
	return result
}

func slashSubsequence(name, prefix string) bool {
	for _, letter := range prefix {
		at := strings.IndexRune(name, letter)
		if at < 0 {
			return false
		}
		name = name[at+len(string(letter)):]
	}
	return true
}

func slashInsertion(choice string) string {
	for _, command := range nativeSlashCommands {
		if command.name == choice && command.acceptsArgs {
			return choice + " "
		}
	}
	return choice
}

func nativeSlashHelp() string {
	var lines []string
	for _, command := range nativeSlashCommands {
		lines = append(lines, command.name+" — "+command.description)
	}
	return strings.Join(lines, "\n")
}
