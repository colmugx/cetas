//go:build !windows && cgo

package bridge

import (
    "os"
    "path/filepath"
    "strings"
    "testing"
)

// Both allocator configurations must implement the heap diagnostics contract.
// In a system-allocator build the file explicitly says that mimalloc stats
// are unavailable; most importantly, linking this test must not pull in
// undefined mi_collect or mi_stats_print_out symbols.
func TestHeapStatsFile(t *testing.T) {
    output := filepath.Join(t.TempDir(), "heap-stats.txt")
    HeapStats(output)
    data, err := os.ReadFile(output)
    if err != nil {
        t.Fatalf("read heap stats: %v", err)
    }
    if len(data) == 0 {
        t.Fatal("heap stats file is empty")
    }
    if strings.Contains(string(data), "mimalloc statistics unavailable") {
        t.Log("system allocator reports no mimalloc-specific metrics")
    }
}
