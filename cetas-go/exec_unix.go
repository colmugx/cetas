//go:build unix

package main

import (
	"os"
	"syscall"
)

// replaceProcess hands the current process over to argv[0]: same PID, same
// descriptors, same controlling terminal, same process group. It returns only
// when the handover failed, so callers must treat a nil error as unreachable.
func replaceProcess(path string, argv []string) error {
	return syscall.Exec(path, argv, os.Environ())
}
