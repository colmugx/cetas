package tui

// markdownCacheBudget is the hard byte budget for settled Markdown renders.
// It is accounted on every insert, so a long session cannot silently retain
// every render it ever produced.
const markdownCacheBudget = 8 << 20

// markdownCache is a byte-bounded LRU of rendered Markdown for settled
// transcript blocks. A miss re-renders from the block's raw source —
// synchronously for small sources, through the cold worker for giant ones —
// so eviction costs a bounded re-render instead of unbounded retention.
//
// The zero value and a nil pointer behave as an always-empty cache: reads
// miss, writes drop. The model owns one instance for its lifetime; value
// copies of the model share it, exactly like the row cache.
type markdownCache struct {
	budget     int
	used       int
	entries    map[int]*markdownCacheEntry
	head, tail *markdownCacheEntry
	evictions  int
}

type markdownCacheEntry struct {
	block          int
	rendered       string
	prev, next     *markdownCacheEntry
}

func newMarkdownCache(budget int) *markdownCache {
	return &markdownCache{budget: max(0, budget), entries: make(map[int]*markdownCacheEntry)}
}

// get returns the cached render for a block and marks it recently used.
func (c *markdownCache) get(index int) (string, bool) {
	if c == nil {
		return "", false
	}
	entry, ok := c.entries[index]
	if !ok {
		return "", false
	}
	c.touch(entry)
	return entry.rendered, true
}

// put stores one render. A render larger than the whole budget is not cached:
// the giant-source path streams from the raw block instead.
func (c *markdownCache) put(index int, rendered string) {
	if c == nil || c.budget == 0 || len(rendered) > c.budget {
		return
	}
	if old, ok := c.entries[index]; ok {
		c.drop(old)
	}
	entry := &markdownCacheEntry{block: index, rendered: rendered}
	entry.next = c.head
	if c.head != nil {
		c.head.prev = entry
	}
	c.head = entry
	if c.tail == nil {
		c.tail = entry
	}
	c.entries[index] = entry
	c.used += len(rendered)
	for c.used > c.budget && c.tail != nil && c.tail != c.head {
		c.drop(c.tail)
	}
}

func (c *markdownCache) drop(entry *markdownCacheEntry) {
	if entry.prev != nil {
		entry.prev.next = entry.next
	} else {
		c.head = entry.next
	}
	if entry.next != nil {
		entry.next.prev = entry.prev
	} else {
		c.tail = entry.prev
	}
	entry.prev, entry.next = nil, nil
	c.used -= len(entry.rendered)
	delete(c.entries, entry.block)
	c.evictions++
}

func (c *markdownCache) touch(entry *markdownCacheEntry) {
	if c.head == entry {
		return
	}
	if entry.prev != nil {
		entry.prev.next = entry.next
	}
	if entry.next != nil {
		entry.next.prev = entry.prev
	} else {
		c.tail = entry.prev
	}
	entry.prev, entry.next = nil, c.head
	if c.head != nil {
		c.head.prev = entry
	}
	c.head = entry
}

// delete drops one block's render, when its source changed or was removed.
func (c *markdownCache) delete(index int) {
	if c == nil {
		return
	}
	if entry, ok := c.entries[index]; ok {
		c.drop(entry)
	}
}

// reset drops every render (theme/width change, session switch, replay).
func (c *markdownCache) reset() {
	if c == nil {
		return
	}
	c.used = 0
	c.head, c.tail = nil, nil
	c.entries = make(map[int]*markdownCacheEntry)
}

// insert re-keys every block at or after `at` by `count`, matching a
// transcript insertion. LRU order is unchanged: it ranks recency, not index.
func (c *markdownCache) insert(at, count int) {
	if c == nil || count <= 0 || len(c.entries) == 0 {
		return
	}
	moved := make([]*markdownCacheEntry, 0, len(c.entries))
	for index, entry := range c.entries {
		delete(c.entries, index)
		if entry.block >= at {
			entry.block += count
		}
		moved = append(moved, entry)
	}
	for _, entry := range moved {
		c.entries[entry.block] = entry
	}
}

// shift re-keys blocks after a removal at `removed` and drops its render.
func (c *markdownCache) shift(removed int) {
	if c == nil || len(c.entries) == 0 {
		return
	}
	c.delete(removed)
	if len(c.entries) == 0 {
		return
	}
	moved := make([]*markdownCacheEntry, 0, len(c.entries))
	for index, entry := range c.entries {
		delete(c.entries, index)
		if entry.block > removed {
			entry.block--
		}
		moved = append(moved, entry)
	}
	for _, entry := range moved {
		c.entries[entry.block] = entry
	}
}

// markdownCacheStats is the observable state; tests assert reuse and bounds
// from these counters instead of timings.
type markdownCacheStats struct {
	used      int
	entries   int
	evictions int
}

func (c *markdownCache) stats() markdownCacheStats {
	if c == nil {
		return markdownCacheStats{}
	}
	return markdownCacheStats{used: c.used, entries: len(c.entries), evictions: c.evictions}
}
