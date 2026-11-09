package tui

import (
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

// Unlike the short-line index microbenchmark, this exercises the production
// wheel reducer, presentation update and View with full-sized message bodies.
func BenchmarkScrollWorkload(b *testing.B) {
	for _, kind := range []string{"short_history", "long_plain", "long_markdown", "collapsed_tool"} {
		b.Run(kind, func(b *testing.B) {
			m := scrollWorkload(kind)
			defer m.Close()
			m.scrollTranscript(-100)
			// This is a warm-scroll benchmark, not time stolen from an
			// unmeasured background render. Settle the cold fixture first.
			deadline := time.Now().Add(5 * time.Second)
			for m.historyMarkdownPending() {
				if time.Now().After(deadline) {
					b.Fatal("cold Markdown fixture did not settle")
				}
				time.Sleep(time.Millisecond)
				m.refreshTranscript()
			}
			// Bound the measurement buffer even for long benchmark runs. These
			// samples time Update+View only, excluding the reset-to-tail setup.
			latencies := make([]time.Duration, 0, min(b.N, 4096))
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				started := time.Now()
				next, _ := m.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp}))
				m = next.(model)
				_ = m.View()
				if len(latencies) < cap(latencies) {
					latencies = append(latencies, time.Since(started))
				}
				if m.virtualScroll.top == 0 {
					m.scrollTranscript(1 << 25)
					m.scrollTranscript(-100)
				}
			}
			b.StopTimer()
			sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
			if len(latencies) > 0 {
				b.ReportMetric(float64(latencies[(len(latencies)-1)*95/100].Nanoseconds()), "p95-ns/event")
			}
			b.Logf("mounted_rows=%d viewport_rows=%d blocks=%d", m.virtualScroll.mountedRows, m.viewport.Height(), m.virtualScroll.renderedBlocks)
		})
	}
}

func scrollWorkload(kind string) model {
	m := newModel()
	m.width, m.height = 108, 36
	m.welcomeHidden = true
	m.resize()
	switch kind {
	case "short_history":
		for i := 0; i < 10000; i++ {
			m.transcript = append(m.transcript, fmt.Sprintf("history %d", i))
		}
	case "long_plain":
		m.transcript = append(m.transcript, strings.Repeat("source line with 中文 and enough text to wrap across narrower terminals\n", 4096))
	case "long_markdown":
		m.appendAssistant(strings.Repeat("paragraph with **bold** and `code` and 中文.\n\n", 4096))
	case "collapsed_tool":
		m.applyEvent(event(`{"type":"tool.started","tool_call_id":"large-read","tool_name":"read","arguments":{"path":"large.txt"}}`))
		m.applyEvent(event(fmt.Sprintf(`{"type":"tool.completed","tool_call_id":"large-read","tool_name":"read","is_error":false,"result":%q}`, strings.Repeat("tool output line with 中文 and text\n", 16384))))
		for i := 0; i < 100; i++ {
			m.transcript = append(m.transcript, fmt.Sprintf("history %d", i))
		}
	}
	m.refreshTranscript()
	return m
}

func TestLongBlockMountsOnlyViewportRows(t *testing.T) {
	for _, kind := range []string{"long_plain", "long_markdown"} {
		t.Run(kind, func(t *testing.T) {
			m := scrollWorkload(kind)
			defer m.Close()
			m.scrollTranscript(-100)
			// Both ends may have overscan, regardless of the block's full height.
			if got, limit := m.virtualScroll.mountedRows, m.viewport.Height()+2*virtualOverscanRows; got > limit {
				t.Fatalf("mounted %d rows for a %d-row viewport (limit %d): block-size virtualization is not row virtualization", got, m.viewport.Height(), limit)
			}
		})
	}
}
