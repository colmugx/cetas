package tui

import (
	"errors"
	"strings"
	"testing"
)

func TestHistoryFailureDoesNotRestartAnIdleClockLoop(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.transcript = []string{strings.Repeat("x", historyMarkdownSyncLimit+1)}
	m.markdownRaw = map[int]string{0: m.transcript[0]}
	v := newVirtualTranscript(m.viewport.Width(), m.viewport.Height())
	m.virtualScroll = v
	w := m.viewport.Width()
	v.sync(1, w, m.viewport.Height(), m.rawTranscriptBlock, func(index int, raw string) int {
		return m.estimateBlockHeight(index, raw, w)
	})
	v.history = newHistoryMarkdownWorker(1)
	v.history.finish(historyMarkdownResult{index: 0, key: historyMarkdownKey{
		epoch: v.epoch, revision: v.revisionAt(0), width: m.viewport.Width(), themeKey: m.markdownThemeIdentity(),
	}, err: errors.New("fixture renderer failed")})
	m.pumpHistoryMarkdown()
	if !strings.Contains(m.err, "fixture renderer failed") {
		t.Fatal("render failure was hidden")
	}
	_ = m.transcriptBlockText(0)
	if m.historyMarkdownPending() {
		t.Fatal("unchanged failed source immediately started another render/clock chain")
	}
}

func TestHistoryResultRetentionHasAByteBound(t *testing.T) {
	worker := newHistoryMarkdownWorker(1)
	defer worker.stop()
	for i := 0; i < 8; i++ {
		worker.finish(historyMarkdownResult{index: i, rendered: strings.Repeat("r", 2<<20)})
	}
	size := 0
	for _, result := range worker.results {
		size += len(result.rendered)
	}
	if size > 8<<20 {
		t.Fatalf("count-limited results retained %d bytes", size)
	}
	worker.finish(historyMarkdownResult{index: 99, rendered: strings.Repeat("r", (8<<20)+1)})
	result := worker.results[99]
	if result.err == nil || result.rendered != "" {
		t.Fatal("one oversized result silently bypassed the byte bound")
	}
}
