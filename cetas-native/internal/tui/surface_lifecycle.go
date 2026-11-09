package tui

import (
	"sort"
	"time"
)

func (m *model) expireSurface(now time.Time) {
	expired := func(deadline time.Time) bool { return !deadline.IsZero() && !now.Before(deadline) }
	for _, renders := range []map[string]mountedWidget{m.surface.widgets, m.surface.statuses} {
		for key, render := range renders {
			if expired(render.Expires) {
				delete(renders, key)
			}
		}
	}
	if expired(m.surface.entriesExpires) {
		m.surface.entries = nil
		m.surface.entriesExpires = time.Time{}
	}
	indices := []int{}
	for key, deadline := range m.surface.noticeExpires {
		if expired(deadline) {
			if index, ok := m.surface.notices[key]; ok {
				indices = append(indices, index)
			}
			delete(m.surface.noticeExpires, key)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(indices)))
	for _, index := range indices {
		m.removeNoticeBlock(index)
	}
}

// An expiring extension notice is not a durable message. Removing it must
// shift every source index together; otherwise the next tool result can
// overwrite a neighbouring message. Descending expiry keeps indices stable.
func (m *model) removeNoticeBlock(at int) {
	if at < 0 || at >= len(m.transcript) {
		return
	}
	copy(m.transcript[at:], m.transcript[at+1:])
	m.transcript[len(m.transcript)-1] = ""
	m.transcript = m.transcript[:len(m.transcript)-1]
	for key, index := range m.surface.notices {
		if index == at {
			delete(m.surface.notices, key)
			delete(m.surface.noticeExpires, key)
		} else if index > at {
			m.surface.notices[key] = index - 1
		}
	}
	m.blocks = shiftBlockMap(m.blocks, at)
	m.markdownRaw = shiftBlockMap(m.markdownRaw, at)
	m.markdownCache = shiftBlockMap(m.markdownCache, at)
	for key, index := range m.toolIndex {
		if index == at {
			delete(m.toolIndex, key)
		} else if index > at {
			m.toolIndex[key] = index - 1
		}
	}
	sources := m.hiddenSearchSources[:0]
	for _, source := range m.hiddenSearchSources {
		if source.block == at {
			continue
		}
		if source.block > at {
			source.block--
		}
		sources = append(sources, source)
	}
	clear(m.hiddenSearchSources[len(sources):])
	m.hiddenSearchSources = sources
	if m.searchQuery != "" {
		m.searchHits = transcriptMatches(m.transcript, m.hiddenSearchSources, m.searchQuery)
		m.searchActive = min(m.searchActive, len(m.searchHits)-1)
	}
	m.resetVirtualTranscript()
}

func shiftBlockMap[T any](old map[int]T, removed int) map[int]T {
	if old == nil {
		return nil
	}
	next := make(map[int]T, len(old))
	for index, value := range old {
		if index == removed {
			continue
		}
		if index > removed {
			index--
		}
		next[index] = value
	}
	return next
}

func (m model) extensionStatusLines() []string {
	keys := make([]string, 0, len(m.surface.statuses))
	for key := range m.surface.statuses {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	lines := []string{}
	for _, key := range keys {
		lines = append(lines, m.surface.statuses[key].Lines...)
	}
	return lines
}
