package localipc

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestAcquireAndRelease(t *testing.T) {
	home := t.TempDir()
	first, err := Acquire(home)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := Acquire(home); second != nil || !errors.Is(err, ErrOwnerActive) {
		t.Fatalf("second owner: lease=%v err=%v", second, err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	third, err := Acquire(home)
	if err != nil {
		t.Fatalf("owner did not release after Close: %v", err)
	}
	defer third.Close()
	info, err := os.Stat(filepath.Join(home, ".cetas", "ipc", "owner.lock"))
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("owner lock file should remain in place: info=%v err=%v", info, err)
	}
}

func TestRejectUnsafeLeasePaths(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix permissions and symlinks only")
	}
	for _, tc := range []struct {
		name  string
		setup func(home string) error
	}{
		{"symlink-ipc", func(home string) error {
			if err := os.MkdirAll(filepath.Join(home, ".cetas"), 0700); err != nil {
				return err
			}
			return os.Symlink(home, filepath.Join(home, ".cetas", "ipc"))
		}},
		{"public-ipc", func(home string) error {
			return os.MkdirAll(filepath.Join(home, ".cetas", "ipc"), 0755)
		}},
		{"public-lease", func(home string) error {
			if err := os.MkdirAll(filepath.Join(home, ".cetas", "ipc"), 0700); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(home, ".cetas", "ipc", "owner.lock"), nil, 0644)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			if err := tc.setup(home); err != nil {
				t.Fatal(err)
			}
			if lease, err := Acquire(home); err == nil {
				_ = lease.Close()
				t.Fatal("unsafe lease path accepted")
			}
		})
	}
}

func TestCanonicalizedHomeSharesLease(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix home symlink semantics")
	}
	base := t.TempDir()
	home := filepath.Join(base, "home")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatal(err)
	}
	lease, err := Acquire(home)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if other, err := Acquire(alias); other != nil || !errors.Is(err, ErrOwnerActive) {
		t.Fatalf("alias created a competing owner: lease=%v err=%v", other, err)
	}
}

// A subprocess is essential: a mutex or a process-local boolean would pass
// same-process tests yet allow two distinct Cetas executors and writers.
func TestOwnerLeaseAcrossProcessesAndCrash(t *testing.T) {
	home := t.TempDir()
	child := exec.Command(os.Args[0], "-test.run=^TestOwnerLeaseHelper$")
	child.Env = append(os.Environ(), "CETAS_LEASE_CHILD=1", "CETAS_LEASE_HOME="+home)
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
	ready := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		ready <- strings.TrimSpace(line)
	}()
	select {
	case line := <-ready:
		if line != "ready" {
			t.Fatalf("helper did not acquire owner lease: %q", line)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("helper did not acquire owner lease")
	}
	if competing, err := Acquire(home); competing != nil || !errors.Is(err, ErrOwnerActive) {
		t.Fatalf("separate process did not exclude owner: lease=%v err=%v", competing, err)
	}
	// Killing the owner must release the kernel lease without removing the
	// lock path, editing a PID file, or waiting for a heartbeat timeout.
	if err := child.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = stdin.Close()
	_ = child.Wait()
	var successor *Lease
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		successor, err = Acquire(home)
		if err == nil {
			break
		}
		if !errors.Is(err, ErrOwnerActive) {
			t.Fatal(err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if successor == nil {
		t.Fatalf("crash failed to release owner lease: %v", err)
	}
	defer successor.Close()
}

func TestOwnerLeaseHelper(t *testing.T) {
	if os.Getenv("CETAS_LEASE_CHILD") != "1" {
		return
	}
	lease, err := Acquire(os.Getenv("CETAS_LEASE_HOME"))
	if err != nil {
		fmt.Printf("error: %v\n", err)
		os.Exit(2)
	}
	defer lease.Close()
	fmt.Println("ready")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}
