//go:build windows

package localipc

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestWindowsNamedPipeRequiresOwnerLease(t *testing.T) {
	if listener, err := ListenLocal(nil); listener != nil || err == nil {
		t.Fatalf("accepted listener without owner lease: %v %v", listener, err)
	}
}

func TestWindowsNamedPipeSameUserAndHealthProbe(t *testing.T) {
	home := t.TempDir()
	lease, err := Acquire(home)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	listener, err := ListenLocal(lease)
	if err != nil {
		t.Fatal(err)
	}
	svc, err := StartHealthService(listener, OwnerInfo{
		InstanceID: "windows-owner", RuntimeEpoch: "epoch-windows",
	})
	if err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	defer svc.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	owner, err := ProbeLocal(ctx, home)
	if err != nil {
		t.Fatalf("same-user Windows named-pipe probe: %v", err)
	}
	if owner.InstanceID != "windows-owner" || owner.RuntimeEpoch != "epoch-windows" ||
		len(owner.Capabilities) != 1 || owner.Capabilities[0] != CapabilityHealthPing {
		t.Fatalf("unexpected Windows owner identity: %+v", owner)
	}
	// Another instance, even in the same process, must not bind the
	// existing endpoint or impersonate its health service.
	if duplicate, err := ListenLocal(lease); duplicate != nil || err == nil {
		if duplicate != nil { _ = duplicate.Close() }
		t.Fatalf("second named-pipe listener succeeded: %v", err)
	}
	if err := svc.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := ProbeLocal(ctx, home); err == nil {
		t.Fatal("Windows health pipe remained accessible after owner stopped")
	}
}

func TestWindowsPipePathIsStableAndPrivateACL(t *testing.T) {
	home := t.TempDir()
	lease, err := Acquire(home)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	path, err := windowsPipePath(home)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(path, pipePrefix) || len(path) > 120 {
		t.Fatalf("unexpected Windows named pipe path: %q", path)
	}
	if other, err := windowsPipePath(home); err != nil || other != path {
		t.Fatalf("Windows pipe path is not stable: %q %v", other, err)
	}
	sddl, err := currentUserPipeDACL()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sddl, "D:P(A;;GA;;;SY)(A;;GA;;;S-1-") ||
		strings.Contains(sddl, ";;;WD)") || strings.Contains(sddl, ";;;AU)") {
		t.Fatalf("Windows IPC ACL is not restricted to SYSTEM and the user: %q", sddl)
	}
	// Lack of a server must not create state or return a usable connection.
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	conn, err := DialLocal(ctx, home)
	if conn != nil || err == nil {
		if conn != nil { _ = conn.Close() }
		t.Fatal("client connected without an owner")
	}
	if !errors.Is(ctx.Err(), context.DeadlineExceeded) && err == nil {
		t.Fatalf("missing owner returned success: %v", err)
	}
}
