// Cetas native's composition root. Terminal presentation lives in internal/tui;
// MoonBit/Posoco remains the authority for sessions, tools and permissions.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/colmugx/cetas/cetas-native/harness"
	"github.com/colmugx/cetas/cetas-native/internal/tui"
)

var version = "0.11.3"

const usage = `Cetas agent

Usage:
  cetas                 start the terminal UI
  cetas tui             same, spelled out
  cetas acp [args...]   replace this process with cetas-acp
  cetas run [args...]   replace this process with cetas-run
  cetas --version       print the version
  cetas --help          this help

Inside the UI: /help`

func main() {
	// `cetas tui` is the spelled-out form of the default; strip it so the flags
	// below keep working (`cetas tui --version`).
	args := os.Args[1:]
	for len(args) > 0 && args[0] == "tui" {
		args = args[1:]
	}
	if len(args) > 0 {
		switch args[0] {
		case "--version", "-version", "-v":
			fmt.Println("cetas " + version)
			return
		case "--help", "-h", "-help", "help":
			fmt.Println(usage)
			return
		case "acp", "run":
			launch(args[0], args[1:])
			return
		default:
			fmt.Fprintf(os.Stderr, "cetas: unknown command %q\n\n%s\n", args[0], usage)
			os.Exit(2)
		}
	}
	runTUI()
}

// launch replaces this process with a sibling mode binary. The two modes own
// their own stdio protocol (ACP JSON-RPC, run's stdin task), their own exit
// status and their own signal handling: nothing survives here to relay or
// confuse them, and `cetas acp` never leaves a supervising parent behind.
func launch(mode string, args []string) {
	name := "cetas-" + mode
	path, err := resolveSibling(name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cetas: %v\n%s must sit next to cetas; install.sh installs all three.\n", err, name)
		os.Exit(1)
	}
	if err := replaceProcess(path, append([]string{name}, args...)); err != nil {
		fmt.Fprintf(os.Stderr, "cetas: cannot start %s: %v\n", name, err)
		os.Exit(1)
	}
}

// resolveSibling prefers the directory this executable was installed into, so
// an install directory wins over an unrelated copy earlier on PATH.
func resolveSibling(name string) (string, error) {
	// Go does not implicitly add PATHEXT when probing os.Stat on Windows.
	// Prefer the actual .exe next to cetas rather than falling through to
	// LookPath, which can reject a relative result with exec.ErrDot.
	binary := name
	if runtime.GOOS == "windows" && filepath.Ext(binary) == "" {
		binary += ".exe"
	}
	if self, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(self), binary)
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return exec.LookPath(binary)
}

func runTUI() {
	lifetime, cancel := context.WithCancel(context.Background())
	defer cancel()
	var active atomic.Pointer[harness.Host]
	closeHost := func(host *harness.Host) error {
		ctx, done := context.WithTimeout(context.Background(), 15*time.Second)
		defer done()
		return host.Close(ctx)
	}
	startup := func() (tui.Runtime, bool, error) {
		ctx, done := context.WithTimeout(lifetime, 30*time.Second)
		defer done()
		host, err := harness.Start(ctx)
		if err != nil {
			return nil, false, err
		}
		active.Store(host)
		// Quit may win the startup race. The owner still closes the late runtime.
		if lifetime.Err() != nil {
			if err := closeHost(host); err != nil {
				return nil, false, err
			}
			return nil, false, lifetime.Err()
		}
		return host, host.NeedsSetup(), nil
	}
	// Match the input coalescer's ~16ms cadence. FPS only caps renderer flushes;
	// startupInputFilter is what prevents raw wheel bursts from rebuilding a
	// View per report. Idle application work remains demand-scheduled.

	// Bubble Tea's renderer decides which SGR forms reach the terminal. Fix the
	// startup profile once, before the first frame, so a muxed terminal that
	// explicitly advertises truecolor is not rendered with a 256-color guess.
	env := os.Environ()
	profile := startupColorProfile(colorprofile.Detect(os.Stdout, env), env)
	startProfileEndpoint()
	final, err := tea.NewProgram(tui.New(startup, version), tea.WithFPS(60), tea.WithColorProfile(profile), tea.WithFilter(startupInputFilter(profile, env))).Run()
	if presentation, ok := final.(interface{ Close() }); ok {
		presentation.Close()
	}
	cancel()
	if host := active.Load(); host != nil {
		if closeErr := closeHost(host); closeErr != nil {
			fmt.Fprintln(os.Stderr, "shutdown:", closeErr)
			if err == nil {
				err = closeErr
			}
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
