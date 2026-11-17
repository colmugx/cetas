//go:build windows

package localipc

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

var errLocked = errors.New("owner lock held")

const (
	lockfileFailImmediately = 0x00000001
	lockfileExclusiveLock   = 0x00000002
	errorLockViolation      = syscall.Errno(33)
)

var (
	kernel32     = syscall.NewLazyDLL("kernel32.dll")
	lockFileEx   = kernel32.NewProc("LockFileEx")
	unlockFileEx = kernel32.NewProc("UnlockFileEx")
)

// The lease file is not an authentication credential. The local named-pipe
// endpoint must separately enforce a current-user SID ACL in M4.4b.
func checkDirectorySecurity(os.FileInfo, bool) error { return nil }
func checkFileSecurity(os.FileInfo) error             { return nil }

func lockFile(file *os.File) error {
	var overlapped syscall.Overlapped
	r, _, callErr := lockFileEx.Call(
		file.Fd(), uintptr(lockfileExclusiveLock|lockfileFailImmediately),
		0, 1, 0, uintptr(unsafe.Pointer(&overlapped)),
	)
	if r == 0 {
		if errors.Is(callErr, errorLockViolation) {
			return errLocked
		}
		return fmt.Errorf("LockFileEx: %w", callErr)
	}
	return nil
}

func unlockFile(file *os.File) error {
	var overlapped syscall.Overlapped
	r, _, callErr := unlockFileEx.Call(file.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&overlapped)))
	if r == 0 {
		return fmt.Errorf("UnlockFileEx: %w", callErr)
	}
	return nil
}
