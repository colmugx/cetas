//go:build unix

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// `cetas acp` and `cetas run` must hand the process over (execve), not fork a
// child: the mode binary inherits the terminal, the process group and the exit
// status directly, and no supervising cetas is left to relay signals.
func TestModesReplaceTheProcessInsteadOfSpawning(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the cgo binary")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain unavailable")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "cetas")
	build := exec.Command("go", "build", "-o", binary, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("build cetas: %v", err)
	}

	for _, mode := range []string{"acp", "run"} {
		t.Run(mode, func(t *testing.T) {
			sibling := filepath.Join(dir, "cetas-"+mode)
			script := "#!/bin/sh\nprintf '%s|%s\\n' \"$$\" \"$*\"\n"
			if err := os.WriteFile(sibling, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			defer os.Remove(sibling)

			cmd := exec.Command(binary, mode, "alpha", "beta")
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("cetas %s: %v", mode, err)
			}
			pid, rest, found := strings.Cut(strings.TrimSpace(string(out)), "|")
			if !found {
				t.Fatalf("sibling did not report itself: %q", out)
			}
			if got, want := pid, strconv.Itoa(cmd.Process.Pid); got != want {
				t.Fatalf("%s ran as pid %s, cetas was %s: that is a subprocess, not a handover", mode, got, want)
			}
			if rest != "alpha beta" {
				t.Fatalf("arguments not passed through: %q", rest)
			}
		})
	}

	t.Run("missing", func(t *testing.T) {
		// A cetas-acp on PATH is a legitimate fallback, so this case needs an
		// empty PATH to mean "not installed at all".
		t.Setenv("PATH", t.TempDir())
		cmd := exec.Command(binary, "acp")
		out, err := cmd.CombinedOutput()
		if err == nil {
			t.Fatal("a missing cetas-acp must fail instead of starting a UI")
		}
		if !strings.Contains(string(out), "cetas-acp") {
			t.Fatalf("failure does not name the missing binary: %q", out)
		}
	})
}
