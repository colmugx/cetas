package tui

import (
	"fmt"
	"strings"
	"testing"
)

func TestSinglePhysicalLineOnlyAllocatesItsWindow(t *testing.T) {
	layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: 40}, strings.Repeat("x", 8192))
	allocs := testing.AllocsPerRun(3, func() {
		rows := layout.rowsInto(nil, 100, 108)
		if len(rows) != 8 {
			panic("wrong row count")
		}
	})
	if allocs > 80 {
		t.Fatalf("8 visible rows allocated the whole physical line: %.0f allocations", allocs)
	}
}

func BenchmarkGiantSingleLineWindow(b *testing.B) {
	for _, size := range []int{64 << 10, 1 << 20} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: 108}, strings.Repeat("x", size))
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				from := i % (layout.height() - 64)
				_ = layout.rowsInto(nil, from, from+47)
			}
		})
	}
}
