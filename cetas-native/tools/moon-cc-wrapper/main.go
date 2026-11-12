// MoonBit invokes this executable through MOON_CC_WRAPPER:
// moon-cc-wrapper <compiler> [compile arguments...]
//
// It covers generated MoonBit C, C stubs, and the runtime. For a native
// library the final linker still controls which sections survive.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

func sizeFlags(goos string) []string {
	switch goos {
	case "windows":
		// MSVC size-first build. /GL enables link-time optimization with /LTCG.
		return []string{"/O1", "/Gw", "/GL"}
	case "linux", "darwin":
		return []string{"-Os", "-ffunction-sections", "-fdata-sections"}
	default:
		return nil
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: moon-cc-wrapper <compiler> [args...]")
		os.Exit(2)
	}
	compiler := os.Args[1]
	// Moon's default /O2 or -O2 precedes this wrapper's flags, so the final
	// optimization setting wins without replacing any required Moon flags.
	args := append(os.Args[2:], sizeFlags(runtime.GOOS)...)
	cmd := exec.Command(compiler, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "moon-cc-wrapper: %s: %v\n", compiler, err)
		os.Exit(1)
	}
}
