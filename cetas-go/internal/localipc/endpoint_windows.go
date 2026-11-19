//go:build windows

package localipc

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	winio "github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

// Windows named-pipe endpoints use byte-stream, cancellable overlapped I/O.
// No TCP/HTTP fallback is permitted: remote clients and other Windows users
// must not get access to the owner's IPC protocol.
const pipePrefix = `\\.\pipe\cetas-`

func windowsPipePath(home string) (string, error) {
	root, err := filepath.Abs(home)
	if err != nil {
		return "", fmt.Errorf("resolve Windows IPC home: %w", err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("canonicalize Windows IPC home: %w", err)
	}
	// Ensure caller is referring to a real initialized Cetas home, without
	// creating it. A missing owner should never make DialLocal create state.
	if err := checkDirectory(filepath.Join(root, ".cetas", "ipc"), true); err != nil {
		return "", err
	}
	// Windows filenames are case-insensitive for the ordinary profile/home
	// paths we support. Normalize path case to avoid distinct pipe names.
	sum := sha256.Sum256([]byte(strings.ToLower(root)))
	return pipePrefix + hex.EncodeToString(sum[:16]), nil
}

func currentUserPipeDACL() (string, error) {
	tokenUser, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("resolve Windows user identity for IPC ACL: %w", err)
	}
	sid := tokenUser.User.Sid.String()
	if sid == "" {
		return "", errors.New("Windows IPC user SID is empty")
	}
	// Protected DACL: SYSTEM and the current user only. No Everyone,
	// Authenticated Users, Administrators or remote access grants.
	return "D:P(A;;GA;;;SY)(A;;GA;;;" + sid + ")", nil
}

// ListenLocal is only available to the opt-in owner holding the OS lease.
// go-winio creates a first-instance-only pipe with proper overlapped I/O,
// supports deadline and close cancellation, and rejects remote clients.
func ListenLocal(lease *Lease) (net.Listener, error) {
	if lease == nil || lease.file == nil {
		return nil, errors.New("Windows IPC listener requires an owner lease")
	}
	if _, err := lease.file.Stat(); err != nil {
		return nil, fmt.Errorf("Windows IPC owner lease unavailable: %w", err)
	}
	// Lease file is <canonical home>/.cetas/ipc/owner.lock.
	home := filepath.Dir(filepath.Dir(filepath.Dir(lease.file.Name())))
	path, err := windowsPipePath(home)
	if err != nil {
		return nil, err
	}
	acl, err := currentUserPipeDACL()
	if err != nil {
		return nil, err
	}
	listener, err := winio.ListenPipe(path, &winio.PipeConfig{
		SecurityDescriptor: acl,
		InputBufferSize:  64 << 10,
		OutputBufferSize: 64 << 10,
	})
	if err != nil {
		return nil, fmt.Errorf("listen on same-user Cetas named pipe: %w", err)
	}
	return listener, nil
}

// DialLocal connects to the explicitly opted-in local owner's Windows pipe.
// It never acquires a lease, composes an Agent, or creates a new pipe.
func DialLocal(ctx context.Context, home string) (net.Conn, error) {
	path, err := windowsPipePath(home)
	if err != nil {
		return nil, err
	}
	return winio.DialPipeContext(ctx, path)
}
