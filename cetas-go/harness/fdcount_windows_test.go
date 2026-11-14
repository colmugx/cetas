//go:build windows

package harness

import "testing"

// Windows has no descriptor table to probe this way (handles are not a dense
// integer range), so the leak check is declared unsupported instead of being
// silently weakened.
func countOpenDescriptors(t *testing.T) int {
	t.Helper()
	t.Skip("descriptor accounting is POSIX-only")
	return 0
}
