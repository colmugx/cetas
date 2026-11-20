package harness

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/colmugx/cetas/cetas-go/internal/localipc"
)

// A second terminal is a viewer candidate, not a native startup failure.
// In particular, ordinary kernel lease contention must never reach Errors()
// and paint a red error in the TUI.
func TestLocalOwnerElectionContentionIsSilent(t *testing.T) {
	home := t.TempDir()
	owner := newHost(nil)
	owner.electLocalSessionOwner(home)
	if owner.ownerLease == nil || owner.ownerReleased == nil {
		t.Fatal("first terminal did not acquire owner lease")
	}
	defer owner.ownerLease.Close()

	viewer := newHost(nil)
	viewer.electLocalSessionOwner(home)
	if viewer.ownerLease != nil || viewer.ownerReleased != nil {
		t.Fatal("second terminal acquired competing local owner lease")
	}
	select {
	case diagnostic := <-viewer.Errors():
		t.Fatalf("ordinary owner contention generated red startup diagnostic: %v", diagnostic)
	default:
	}
	// A subsequent election must still see the first owner's kernel lock.
	lease, err := localipc.Acquire(home)
	if lease != nil {
		_ = lease.Close()
		t.Fatal("second terminal released or bypassed the first owner's lease")
	}
	if !errors.Is(err, localipc.ErrOwnerActive) {
		t.Fatalf("expected first owner to retain its lease: %v", err)
	}
}

// Only the expected ErrOwnerActive is silent. Unsafe paths and unexpected
// owner election errors still reach the diagnostic channel.
func TestLocalOwnerElectionRealFailureStillReported(t *testing.T) {
	home := filepath.Join(t.TempDir(), "missing-home")
	if _, err := os.Stat(home); !os.IsNotExist(err) {
		t.Fatalf("missing-home test setup failed: %v", err)
	}
	h := newHost(nil)
	h.electLocalSessionOwner(home)
	if h.ownerLease != nil {
		t.Fatal("unexpectedly obtained owner lease from missing home")
	}
	select {
	case err := <-h.Errors():
		if err == nil || !strings.Contains(err.Error(), "optional native local owner unavailable") {
			t.Fatalf("unexpected diagnostic: %v", err)
		}
		if errors.Is(err, localipc.ErrOwnerActive) {
			t.Fatal("real election failure was reclassified as expected contention")
		}
	default:
		t.Fatal("real local IPC election error was silently discarded")
	}
}
