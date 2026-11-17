//go:build !windows

package localipc

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

var ErrEndpointActive = errors.New("Cetas local IPC endpoint is already active")

const socketName = "owner.sock"

// unixSocketPath uses the canonical Cetas home to derive a stable, short
// socket path. macOS limits sockaddr_un.sun_path to roughly 104 bytes and
// neither a deep home nor macOS's long TMPDIR can safely be used directly.
// /tmp is a short Unix-local parent, with a 0700 per-user/per-home directory.
// The OS owner lease in home/.cetas/ipc remains the execution authority.
func unixSocketPath(home string) (string, error) {
	root, err := filepath.Abs(home)
	if err != nil {
		return "", fmt.Errorf("resolve IPC home: %w", err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("canonicalize IPC home: %w", err)
	}
	if err := checkDirectory(filepath.Join(root, ".cetas", "ipc"), true); err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(root))
	dir := filepath.Join("/tmp", fmt.Sprintf("cetas-%d-%x", os.Geteuid(), digest[:12]))
	return filepath.Join(dir, socketName), nil
}

type ownedUnixListener struct {
	*net.UnixListener
	path string
	identity os.FileInfo
}

func (l *ownedUnixListener) Close() error {
	err := l.UnixListener.Close()
	// Do not unlink a pathname that no longer refers to our bound socket.
	if info, statErr := os.Lstat(l.path); statErr == nil {
		if os.SameFile(info, l.identity) {
			err = errors.Join(err, os.Remove(l.path))
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		err = errors.Join(err, statErr)
	}
	return err
}

// ListenLocal binds a per-home Unix socket only while the caller owns the
// M4.4a kernel lease. The caller must close the listener BEFORE releasing the
// lease. A stale socket is only removed with the election lease held, and an
// active or ambiguous endpoint is never stolen.
func ListenLocal(lease *Lease) (net.Listener, error) {
	if lease == nil || lease.file == nil {
		return nil, errors.New("local IPC listener requires an owner lease")
	}
	if _, err := lease.file.Stat(); err != nil {
		return nil, fmt.Errorf("local IPC lease unavailable: %w", err)
	}
	// Lease file is <canonical home>/.cetas/ipc/owner.lock.
	home := filepath.Dir(filepath.Dir(filepath.Dir(lease.file.Name())))
	path, err := unixSocketPath(home)
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(path)
	if err := os.Mkdir(dir, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, fmt.Errorf("create private local IPC directory: %w", err)
	}
	if err := checkDirectory(dir, true); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("refusing non-socket IPC endpoint %s", path)
		}
		conn, dialErr := net.DialTimeout("unix", path, 200*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			return nil, ErrEndpointActive
		}
		if !errors.Is(dialErr, syscall.ECONNREFUSED) {
			return nil, fmt.Errorf("ambiguous existing IPC endpoint: %w", dialErr)
		}
		current, statErr := os.Lstat(path)
		if statErr != nil || !os.SameFile(info, current) {
			return nil, errors.New("local IPC endpoint changed during stale inspection")
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("remove verified stale IPC socket: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	addr := &net.UnixAddr{Name: path, Net: "unix"}
	l, err := net.ListenUnix("unix", addr)
	if err != nil {
		return nil, fmt.Errorf("bind local IPC socket: %w", err)
	}
	// net.UnixListener by default unlinks paths on Close. Take ownership of
	// cleanup so path identity can be verified before removing it.
	l.SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0600); err != nil {
		_ = l.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("restrict local IPC socket: %w", err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		_ = l.Close()
		return nil, err
	}
	return &ownedUnixListener{UnixListener: l, path: path, identity: info}, nil
}

// DialLocal does not attempt owner election or create runtime state. It
// connects only to an existing endpoint within a private per-user directory.
func DialLocal(ctx context.Context, home string) (net.Conn, error) {
	path, err := unixSocketPath(home)
	if err != nil {
		return nil, err
	}
	if err := checkDirectory(filepath.Dir(path), true); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("unsafe local IPC socket")
	}
	return (&net.Dialer{}).DialContext(ctx, "unix", path)
}
