//go:build !windows

package localipc

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

var errLocked = errors.New("owner lock held")

func checkDirectorySecurity(info os.FileInfo, private bool) error {
	if uid, ok := info.Sys().(*syscall.Stat_t); ok && uid.Uid != uint32(os.Geteuid()) {
		return errors.New("directory is not owned by the current user")
	}
	if info.Mode().Perm()&0022 != 0 {
		return errors.New("directory is group/world writable")
	}
	if private && info.Mode().Perm()&0077 != 0 {
		return errors.New("private IPC directory allows group/world access")
	}
	return nil
}

func checkFileSecurity(info os.FileInfo) error {
	if uid, ok := info.Sys().(*syscall.Stat_t); ok && uid.Uid != uint32(os.Geteuid()) {
		return errors.New("lease file is not owned by the current user")
	}
	if info.Mode().Perm()&0077 != 0 {
		return errors.New("lease file allows group/world access")
	}
	return nil
}

func lockFile(file *os.File) error {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return errLocked
	}
	if err != nil {
		return fmt.Errorf("flock: %w", err)
	}
	return nil
}

func unlockFile(file *os.File) error {
	return syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}
