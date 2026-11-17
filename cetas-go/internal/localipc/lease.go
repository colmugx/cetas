// Package localipc provides the OS-enforced process-owner lease used before
// composing a native Cetas runtime. It is not an IPC server or client yet.
package localipc

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// ErrOwnerActive means another process holds the local runtime lease.
// Callers must attach through IPC when available, never compose a second Agent.
var ErrOwnerActive = errors.New("another Cetas runtime owns this home (local IPC client not available yet)")

// Lease keeps the kernel lock alive for the lifetime of the native runtime.
// The file is never unlinked: removing it permits a second inode and a
// competing owner while a former owner still holds the original lock.
type Lease struct {
	file     *os.File
	once     sync.Once
	closeErr error
}

// Home resolves CETAS_HOME like cetas-core's cetas_home: non-empty override,
// then the platform user home, with '.' as the last-resort fallback.
func Home() string {
	if home := strings.TrimSpace(os.Getenv("CETAS_HOME")); home != "" {
		return home
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "."
}

// Acquire obtains the per-home owner lease before any runtime composition.
// It returns immediately if another process owns the lock. Lease.Close must
// run only after every owned Agent and Session writer has stopped.
func Acquire(home string) (*Lease, error) {
	root, err := filepath.Abs(home)
	if err != nil {
		return nil, fmt.Errorf("resolve local owner home: %w", err)
	}
	// Canonicalize aliases (including a symlinked home) so two spellings
	// of the same home cannot elect independent owners.
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("resolve local owner home symlinks: %w", err)
	}

	state := filepath.Join(root, ".cetas")
	if err := os.MkdirAll(state, 0700); err != nil {
		return nil, fmt.Errorf("create Cetas state directory: %w", err)
	}
	if err := checkDirectory(state, false); err != nil {
		return nil, err
	}
	private := filepath.Join(state, "ipc")
	if err := os.Mkdir(private, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, fmt.Errorf("create private IPC directory: %w", err)
	}
	if err := checkDirectory(private, true); err != nil {
		return nil, err
	}

	path := filepath.Join(private, "owner.lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, fmt.Errorf("open local owner lease: %w", err)
	}
	// OpenFile can follow a symlink. Reject a replaced or non-regular path
	// before attempting to lock; a private IPC directory prevents other
	// local users from swapping entries under this process.
	if err := checkLockFile(file, path); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err := lockFile(file); err != nil {
		_ = file.Close()
		if errors.Is(err, errLocked) {
			return nil, ErrOwnerActive
		}
		return nil, fmt.Errorf("acquire local owner lease: %w", err)
	}
	// Never unlink this lock file on Close or on process exit.
	return &Lease{file: file}, nil
}

func checkDirectory(path string, private bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect local owner directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("local owner path is not a real directory: %s", path)
	}
	if err := checkDirectorySecurity(info, private); err != nil {
		return fmt.Errorf("unsafe local owner directory %s: %w", path, err)
	}
	return nil
}

func checkLockFile(file *os.File, path string) error {
	opened, err := file.Stat()
	if err != nil {
		return fmt.Errorf("inspect local owner lease: %w", err)
	}
	entry, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect local owner lease path: %w", err)
	}
	if !opened.Mode().IsRegular() || !entry.Mode().IsRegular() || !os.SameFile(opened, entry) {
		return fmt.Errorf("local owner lease is not a stable regular file: %s", path)
	}
	if err := checkFileSecurity(opened); err != nil {
		return fmt.Errorf("unsafe local owner lease %s: %w", path, err)
	}
	return nil
}

// Close releases the kernel lock and closes its handle. A crash closes the
// handle in the OS; no heartbeat, stale PID check or lock-file unlink is used.
func (l *Lease) Close() error {
	if l == nil {
		return nil
	}
	l.once.Do(func() {
		l.closeErr = errors.Join(unlockFile(l.file), l.file.Close())
	})
	return l.closeErr
}
