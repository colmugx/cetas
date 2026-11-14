package tui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// Transcript search reads source blocks, never the rendered viewport. In
// particular, hidden tool output and reasoning can be searched while they
// remain collapsed in the terminal. Search is only performed on demand.
//
// A paged replay cannot search its own model: it holds placeholders, and a block
// body above REPLAY_INLINE_BYTES is only a REPLAY_PREVIEW_CHARS preview. /find
// therefore hands the query to the paged source scan (paged_transcript.go), which
// walks the console corpus page by page and streams every deferred payload
// through `transcript_source` in bounded ranges. The helpers below stay the one
// definition of a match, shared by both paths.
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

// hitsAt returns the matches of one block from a search snapshot. Hits are
// appended in increasing block order, so a repaint needs a lower-bound lookup
// instead of scanning every match in the session.
func hitsAt(hits []transcriptSearchHit, block int) []transcriptSearchHit {
	low, high := 0, len(hits)
	for low < high {
		middle := low + (high-low)/2
		if hits[middle].block < block {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low >= len(hits) || hits[low].block != block {
		return nil
	}
	end := low + 1
	for end < len(hits) && hits[end].block == block {
		end++
	}
	return hits[low:end]
}

// highlightLiteralRows underlines only literal source matches that can be
// located exactly on a rendered row. Markdown rewrites source text, so an
// uncertain match is left unpainted instead of guessing at display columns.
// Visible width never changes.
func highlightLiteralRows(rows []string, source string, hits []transcriptSearchHit, width int) []string {
	if len(hits) == 0 || source == "" {
		return rows
	}
	sourceLines := strings.Split(source, "\n")
	out := make([]string, len(rows))
	for index, raw := range rows {
		out[index] = raw
		if strings.Contains(raw, "\x1b_G") || strings.Contains(raw, "\x1b]1337;File=") {
			continue
		}
		plain := ansi.Strip(raw)
		type span struct{ start, end int }
		var spans []span
		offset := 0
		for _, line := range sourceLines {
			displayStart := strings.Index(plain, line)
			if line != "" && displayStart >= 0 {
				for _, hit := range hits {
					local := hit.offset - offset
					if local < 0 || local+hit.length > len(line) {
						continue
					}
					start := ansi.StringWidth(plain[:displayStart+local])
					length := ansi.StringWidth(line[local : local+hit.length])
					if start+length <= width {
						spans = append(spans, span{start: start, end: start + length})
					}
				}
			}
			offset += len(line) + 1
		}
		if len(spans) == 0 {
			continue
		}
		sort.Slice(spans, func(a, b int) bool { return spans[a].start > spans[b].start })
		result := raw
		for _, span := range spans {
			total := ansi.StringWidth(result)
			before := ansi.Cut(result, 0, span.start)
			middle := ansi.Cut(result, span.start, span.end)
			after := ansi.Cut(result, span.end, total)
			// Styled undercurl (SGR 4:3) reads as a search hit at a glance;
			// terminals without styled underlines degrade to a plain one.
			result = before + "\x1b[4:3m" + middle + "\x1b[24m" + after
		}
		out[index] = result
	}
	return out
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
	// A running corpus scan must not finish later and re-open hits for a query
	// the model has already forgotten.
	m.replay.cancelScan(m)
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
		m.replay.cancelScan(m)
		m.searchQuery = ""
		m.searchHits = nil
		m.searchActive = -1
		m.status = "usage: /find <text> (or /find-next, /find-prev)"
		return
	}
	m.searchQuery = query
	if m.replay.active() {
		// A paged document holds placeholders, not history: searching the resident
		// window would silently miss every unmounted block, and searching a preview
		// would miss every match past its end. The console scan reads the whole
		// corpus, streams deferred payloads, and reports absolute block indexes; the
		// next frame's ensureTranscriptPages issues its first read.
		m.replay.find(m, query)
		return
	}
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
