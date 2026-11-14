package components

import (
	"strings"
	"testing"
)

func TestAskCacheDoesNotRetainHugePrompts(t *testing.T) {
	askBodies.Lock()
	askBodies.entries = nil
	askBodies.Unlock()
	text := strings.Repeat("large prompt line\n", 300000)
	Ask(Theme{}, AskRequest{Kind: AskSelect, Prompt: "Proceed?\n" + text, Options: []string{"yes", "no"}}, 80, 0, "", false)
	askBodies.Lock()
	defer askBodies.Unlock()
	for _, entry := range askBodies.entries {
		if len(entry.key.text) > 4<<20 {
			t.Fatal("multi-megabyte prompt retained in process-wide cache")
		}
	}
}
