package tui

import (
	"strings"
	"testing"
)

func TestRowCacheBudgetIncludesTheCurrentWindow(t *testing.T) {
	cache := newTranscriptRowCache(1024)
	cache.beginFrame()
	layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: 40}, strings.Repeat("x", 4096))
	cache.store(layout)
	painted := cache.rows(layout, 0, 4)
	cache.trim()
	if cache.used > cache.budget {
		t.Fatalf("current-frame protection bypassed cache budget: %d > %d", cache.used, cache.budget)
	}
	// Evicting cache ownership must not destroy rows already handed to the frame.
	if len(painted) != 4 || strings.TrimSpace(painted[0]) != strings.Repeat("x", 40) {
		t.Fatalf("painted window changed during trim: %q", painted)
	}
}
