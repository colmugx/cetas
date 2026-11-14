//go:build windows

package main

import (
	"errors"
	"os"
	"os/exec"
)

// Windows has no execve: nothing can replace this process image. The closest
// honest equivalent is to run the mode binary with inherited stdio, wait for
// it and exit with its status — one extra PID, no output relay, no captured
// streams. POSIX keeps the strict same-process handover in exec_unix.go.
func replaceProcess(path string, argv []string) error {
	cmd := exec.Command(path, argv[1:]...)
	cmd.Args = argv
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	var exited *exec.ExitError
	if errors.As(err, &exited) {
		os.Exit(exited.ExitCode())
	}
	if err != nil {
		return err
	}
	os.Exit(0)
	return nil
}
