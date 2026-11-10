//go:build !windows

package harness

import (
	"syscall"
	"testing"
)

// countOpenDescriptors counts this process's live descriptors by probing, not
// by listing /dev/fd: that directory is not readable in every sandboxed
// runner, and a leak check that dies on the listing proves nothing. Descriptors
// are allocated lowest-first, so a bounded dense probe is enough to notice one
// that was never closed.
func countOpenDescriptors(t *testing.T) int {
	t.Helper()
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		t.Fatalf("rlimit: %v", err)
	}
	end := int(limit.Cur)
	if end > 8192 {
		end = 8192
	}
	open := 0
	for fd := 0; fd < end; fd++ {
		var info syscall.Stat_t
		if err := syscall.Fstat(fd, &info); err == nil {
			open++
		}
	}
	return open
}
