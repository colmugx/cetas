// Cetas native's composition root. Terminal presentation lives in internal/tui;
// MoonBit/Posoco remains the authority for sessions, tools and permissions.
package main

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/colmugx/cetas/cetas-native/harness"
	"github.com/colmugx/cetas/cetas-native/internal/tui"
)

var version = "0.11.0"

func main() {
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--version", "-version":
			fmt.Println("cetas " + version)
			return
		case "--help", "-h":
			fmt.Println("Cetas native terminal\nUsage: cetas [--version|--help]\nInside the UI: /help")
			return
		}
	}
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
