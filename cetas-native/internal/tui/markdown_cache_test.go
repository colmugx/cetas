package tui

import (
	"strings"
	"testing"
)

func newTestMarkdownCache(budget int) *markdownCache {
	return newMarkdownCache(budget)
}

// TestMarkdownCacheBoundsRetentionByBytes pins the reason the type exists:
// however many blocks are rendered, the retained bytes never exceed the
// budget, and the least recently used render is the one evicted.
func TestMarkdownCacheBoundsRetentionByBytes(t *testing.T) {
	c := newTestMarkdownCache(256)
	fill := strings.Repeat("x", 100)
	for index := 0; index < 10; index++ {
		c.put(index, fill)
	}
	stats := c.stats()
	if stats.used > 256 {
		t.Fatalf("cache retained %d bytes over its budget", stats.used)
	}
	if stats.entries != 2 {
		t.Fatalf("cache kept %d entries for a 2-entry budget", stats.entries)
	}
	if stats.evictions != 8 {
		t.Fatalf("evictions = %d, want 8", stats.evictions)
	}
	// The most recent blocks survive; the oldest are gone.
	for _, index := range []int{8, 9} {
		if _, ok := c.get(index); !ok {
			t.Fatalf("recent block %d was evicted", index)
		}
	}
	for _, index := range []int{0, 1, 7} {
		if _, ok := c.get(index); ok {
			t.Fatalf("old block %d survived eviction", index)
		}
	}
	// A read marks recency: after touching 8, block 9 is the LRU one and
	// goes first when the next insert needs room.
	if _, ok := c.get(8); !ok {
		t.Fatal("block 8 missing before the recency probe")
	}
	c.put(10, fill)
	if _, ok := c.get(9); ok {
		t.Fatal("least recently used block survived the next insert")
	}
	if _, ok := c.get(8); !ok {
		t.Fatal("recently used block was evicted instead of the LRU one")
	}
}

// TestMarkdownCacheRefusesOversizedRenders pins the single-entry rule: a
// render larger than the whole budget is never cached, and a nil cache
// degrades to an always-miss instead of panicking.
func TestMarkdownCacheRefusesOversizedRenders(t *testing.T) {
	c := newTestMarkdownCache(64)
	c.put(0, strings.Repeat("y", 65))
	if stats := c.stats(); stats.entries != 0 || stats.used != 0 {
		t.Fatalf("oversized render was cached: %+v", stats)
	}
	c.put(1, strings.Repeat("y", 64))
	if _, ok := c.get(1); !ok {
		t.Fatal("a budget-sized render was refused")
	}
	var nilCache *markdownCache
	if _, ok := nilCache.get(0); ok {
		t.Fatal("nil cache returned a hit")
	}
	nilCache.put(0, "rendered")
	nilCache.delete(0)
	nilCache.reset()
	nilCache.insert(0, 1)
	nilCache.shift(0)
	nilCache.retain(0, 1)
}

// TestMarkdownCacheRekeysOnTranscriptEdits pins index maintenance: inserts
// shift later blocks up, removals shift them down and drop the removed
// render, retain keeps exactly the window, and reset empties everything.
func TestMarkdownCacheRekeysOnTranscriptEdits(t *testing.T) {
	c := newTestMarkdownCache(1 << 20)
	for index := 0; index < 5; index++ {
		c.put(index, string(rune('a'+index)))
	}
	// Insert two blocks before index 3: renders for 3 and 4 move to 5 and 6.
	c.insert(3, 2)
	for _, probe := range []struct {
		index int
		want  string
	}{
		{0, "a"}, {1, "b"}, {2, "c"}, {5, "d"}, {6, "e"},
	} {
		if got, ok := c.get(probe.index); !ok || got != probe.want {
			t.Fatalf("after insert block %d = %q (found=%v), want %q", probe.index, got, ok, probe.want)
		}
	}
	// Remove block 1: later renders shift down.
	c.shift(1)
	for _, probe := range []struct {
		index int
		want  string
	}{
		{0, "a"}, {1, "c"}, {4, "d"}, {5, "e"},
	} {
		if got, ok := c.get(probe.index); !ok || got != probe.want {
			t.Fatalf("after shift block %d = %q (found=%v), want %q", probe.index, got, ok, probe.want)
		}
	}
	// Rotate the run [4, 6) down to 1: the run's entries follow their blocks,
	// the passed-over entry shifts up, and nothing lingers at the old indexes.
	c.rotate(1, 4, 2)
	for _, probe := range []struct {
		index int
		want  string
	}{
		{0, "a"}, {1, "d"}, {2, "e"}, {3, "c"},
	} {
		if got, ok := c.get(probe.index); !ok || got != probe.want {
			t.Fatalf("after rotate block %d = %q (found=%v), want %q", probe.index, got, ok, probe.want)
		}
	}
	for _, index := range []int{4, 5} {
		if _, ok := c.get(index); ok {
			t.Fatalf("rotate left a stale entry at %d", index)
		}
	}
	// Retain a window: every render outside [1, 4) is dropped; the rotated
	// run is exactly what lives inside it.
	c.retain(1, 4)
	if got, ok := c.get(1); !ok || got != "d" {
		t.Fatalf("retain lost the in-window block: %q (found=%v)", got, ok)
	}
	for _, index := range []int{0, 4, 5} {
		if _, ok := c.get(index); ok {
			t.Fatalf("retain kept out-of-window block %d", index)
		}
	}
	// Reset empties the cache but keeps it usable.
	c.reset()
	if stats := c.stats(); stats.entries != 0 || stats.used != 0 {
		t.Fatalf("reset left %+v", stats)
	}
	c.put(0, "fresh")
	if got, ok := c.get(0); !ok || got != "fresh" {
		t.Fatal("cache unusable after reset")
	}
	// Updating an existing block replaces its render without double counting.
	c.put(0, "replacement")
	if got, ok := c.get(0); !ok || got != "replacement" {
		t.Fatal("update did not replace the render")
	}
	if stats := c.stats(); stats.entries != 1 || stats.used != len("replacement") {
		t.Fatalf("update double-counted bytes: %+v", stats)
	}
}
