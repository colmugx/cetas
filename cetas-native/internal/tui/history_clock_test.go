package tui

import (
	"testing"
	"time"
)

func TestColdHistoryRenderOwnsOnlyADemandClock(t *testing.T) {
	m := newModel()
	worker := newHistoryMarkdownWorker(1)
	m.virtualScroll = &virtualTranscript{history: worker}
	defer worker.stop()
	// An uncollected result is work even when no turn or spinner is active.
	worker.results[0] = historyMarkdownResult{index: 0, rendered: "ready"}
	worker.order = []int{0}
	if m.nextUIWake(time.Now()).IsZero() {
		t.Fatal("cold history result has no repaint wake")
	}
	worker.take()
	if !m.nextUIWake(time.Now()).IsZero() {
		t.Fatal("settled history kept an idle clock alive")
	}
}
