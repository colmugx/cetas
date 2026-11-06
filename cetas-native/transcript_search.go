package main

import (
	"fmt"
	"strings"
)

// Transcript search reads source blocks, never the rendered viewport. In
// particular, hidden tool output and reasoning can be searched while they
// remain collapsed in the terminal. Search is only performed on demand.
const maxTranscriptSearchHits = 10000

type transcriptSearchHit struct {
	block  int // index in the visible transcript, for scroll navigation
	offset int // byte offset in the original matched source
	length int
	hidden bool
}

type hiddenTranscriptSource struct {
	block int
	text  string
}

func searchTranscriptSource(text, needle string, block int, hidden bool, out []transcriptSearchHit) []transcriptSearchHit {
	haystack := strings.ToLower(text)
	for from := 0; from < len(haystack) && len(out) < maxTranscriptSearchHits; {
		at := strings.Index(haystack[from:], needle)
		if at < 0 {
			break
		}
		offset := from + at
		out = append(out, transcriptSearchHit{block: block, offset: offset, length: len(needle), hidden: hidden})
		from = offset + len(needle) // non-overlapping, same as cetas-js
	}
	return out
}

// One scan over the complete, unrendered session source. Both exposed and
// collapsed sources are ordered by the transcript block they belong to.
func transcriptMatches(visible []string, hidden []hiddenTranscriptSource, query string) []transcriptSearchHit {
	needle := strings.ToLower(strings.TrimSpace(query))
	if needle == "" {
		return nil
	}
	extras := make(map[int][]string, len(hidden))
	for _, source := range hidden {
		index := source.block
		if index < 0 {
			index = 0
		}
		extras[index] = append(extras[index], source.text)
	}
	hits := make([]transcriptSearchHit, 0)
	for index, text := range visible {
		hits = searchTranscriptSource(text, needle, index, false, hits)
		if len(hits) >= maxTranscriptSearchHits {
			break
		}
		for _, extra := range extras[index] {
			hits = searchTranscriptSource(extra, needle, index, true, hits)
			if len(hits) >= maxTranscriptSearchHits {
				break
			}
		}
	}
	// A session can contain only hidden reasoning (and no visible block).
	if len(visible) == 0 {
		for _, extra := range extras[0] {
			hits = searchTranscriptSource(extra, needle, 0, true, hits)
			if len(hits) >= maxTranscriptSearchHits {
				break
			}
		}
	}
	return hits
}

func (m *model) clearTranscriptSearch() {
	m.searchQuery = ""
	m.searchHits = nil
	m.searchActive = -1
	m.hiddenSearchSources = nil
}

func (m *model) addHiddenSource(block int, text string) {
	if text == "" {
		return
	}
	if block < 0 {
		block = 0
	}
	m.hiddenSearchSources = append(m.hiddenSearchSources, hiddenTranscriptSource{block: block, text: text})
}

func (m *model) findTranscript(query string) {
	query = strings.TrimSpace(query)
	if query == "" {
		m.searchQuery = ""
		m.searchHits = nil
		m.searchActive = -1
		m.status = "usage: /find <text> (or /find-next, /find-prev)"
		return
	}
	m.searchQuery = query
	m.searchHits = transcriptMatches(m.transcript, m.hiddenSearchSources, query)
	m.searchActive = -1
	if len(m.searchHits) == 0 {
		m.status = fmt.Sprintf("no transcript matches for %q", query)
		return
	}
	m.navigateTranscriptSearch(false)
}

func (m *model) navigateTranscriptSearch(reverse bool) {
	if len(m.searchHits) == 0 {
		m.status = "no transcript matches; use /find <text>"
		return
	}
	if m.searchActive < 0 {
		if reverse {
			m.searchActive = len(m.searchHits) - 1
		} else {
			m.searchActive = 0
		}
	} else if reverse {
		m.searchActive = (m.searchActive + len(m.searchHits) - 1) % len(m.searchHits)
	} else {
		m.searchActive = (m.searchActive + 1) % len(m.searchHits)
	}
	hit := m.searchHits[m.searchActive]
	if m.virtualScroll != nil && hit.block >= 0 && hit.block < len(m.virtualScroll.heights) {
		m.jumpToTranscriptBlock(hit.block)
	}
	kind := ""
	if hit.hidden {
		kind = " (collapsed source)"
	}
	m.status = fmt.Sprintf("find %d/%d · entry %d%s · %s",
		m.searchActive+1, len(m.searchHits), hit.block+1, kind, m.searchQuery)
}
