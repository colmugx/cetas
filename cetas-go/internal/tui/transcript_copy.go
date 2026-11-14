package tui

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const maxTranscriptCopyChars = 4_000_000

// transcriptSourceAt returns the original, unrendered source of one transcript
// block. Streaming and reasoning blocks are part of the document, so a source
// read never depends on the mounted window.
func (m *model) transcriptSourceAt(index int) string {
	if index < 0 || index >= m.transcriptBlockCount() {
		return ""
	}
	if index >= len(m.transcript) {
		return m.rawTranscriptBlock(index)
	}
	if raw, ok := m.markdownRaw[index]; ok {
		return raw
	}
	return m.transcript[index]
}

// copySourceRange concatenates the source of an inclusive, 0-based block range
// with a blank line between entries. This is the clipboard contract of the JS
// transcriptTextRange: the original message text, never painted terminal cells,
// so a drag across unmounted history still copies what the user wrote.
func (m *model) copySourceRange(first, last int) (string, error) {
	if first < 0 || last < first || last >= m.transcriptBlockCount() {
		return "", errors.New("invalid transcript copy range")
	}
	if m.replay.active() {
		// A paged document stores placeholders for blocks it does not hold. Copying
		// them would silently drop most of the selection, so the range is pinned
		// for the next ensure and the caller retries once the pages are loaded.
		return m.replay.copyRange(m, first, last)
	}
	return m.copySourceBlocks(first, last)
}

// copySourceBlocks is the clipboard contract of the JS transcriptTextRange: the
// original message text, never painted terminal cells, so a drag across unmounted
// history still copies what the user wrote.
func (m *model) copySourceBlocks(first, last int) (string, error) {
	if first < 0 || last < first || last >= m.transcriptBlockCount() {
		return "", errors.New("invalid transcript copy range")
	}
	var result strings.Builder
	for index := first; index <= last; index++ {
		text := m.transcriptSourceAt(index)
		if text == "" {
			continue
		}
		delimiter := 0
		if result.Len() > 0 {
			delimiter = 2
		}
		if result.Len()+delimiter+len(text) > maxTranscriptCopyChars {
			return "", errors.New("selected transcript text exceeds 4 MB limit")
		}
		if delimiter > 0 {
			result.WriteString("\n\n")
		}
		result.WriteString(text)
	}
	return result.String(), nil
}

// copyTranscriptSource reads the complete settled history, never the mounted
// viewport. Indices are 1-based, matching cetas-js /copyhistory.
func (m *model) copyTranscriptSource(first, last int) (string, error) {
	if first < 1 || last < first || last > len(m.transcript) {
		return "", errors.New("invalid transcript copy range")
	}
	return m.copySourceRange(first-1, last-1)
}

// copyHistoryRange validates the command independently of storage residency, so
// paged history can fetch the range asynchronously without changing its syntax.
func copyHistoryRange(parts []string, count int) (int, int, error) {
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, errors.New("usage: /copyhistory <first> [last] (1-based)")
	}
	first, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, 0, errors.New("invalid first history index")
	}
	last := first
	if len(parts) == 3 {
		last, err = strconv.Atoi(parts[2])
		if err != nil {
			return 0, 0, errors.New("invalid last history index")
		}
	}
	if first < 1 || last < first || last > count {
		return 0, 0, errors.New("invalid transcript copy range")
	}
	return first, last, nil
}

func (m *model) copyHistoryCommand(parts []string) (string, error) {
	first, last, err := copyHistoryRange(parts, len(m.transcript))
	if err != nil {
		return "", err
	}
	text, err := m.copyTranscriptSource(first, last)
	if err != nil {
		return "", err
	}
	if text == "" {
		return "", errors.New("selected transcript entries have no text")
	}
	m.status = fmt.Sprintf("sent transcript entries %d–%d to terminal clipboard", first, last)
	return text, nil
}
