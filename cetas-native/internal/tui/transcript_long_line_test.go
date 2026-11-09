package tui

import (
	"fmt"
	"reflect"
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

func TestLineWindowPreservesCellCutSemantics(t *testing.T) {
	for _, source := range []string{
		strings.Repeat("JSON words 123 ", 12), "a中b👩‍💻c e\u0301",
		"\x1b[31mred 中 text\x1b[0m more", "a\tb\x00c", "", "👩‍💻👩‍💻👩‍💻",
	} {
		for _, width := range []int{1, 2, 3, 8, 40} {
			t.Run(fmt.Sprintf("%q/%d", source, width), func(t *testing.T) {
				layout := newTranscriptBlockLayout(0, transcriptLayoutIdentity{width: width}, source)
				want := wrapTranscriptLine(source, width)
				for i := range want {
					want[i] = padTranscriptRow(want[i], width)
				}
				blank := strings.Repeat(" ", width)
				want = append(want, blank, blank)
				for from := range want {
					to := min(len(want), from+3)
					if got := layout.rowsInto(nil, from, to); !reflect.DeepEqual(got, want[from:to]) {
						t.Fatalf("window %d:%d: got %q want %q", from, to, got, want[from:to])
					}
				}
			})
		}
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
