package tui

import (
	"io"
	"sync/atomic"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

// This drives Filter -> the real transcript reducer -> View, not only the
// coalescer's fake clock. Timings here are logical frame consumption, NOT PTY
// paint latency or a guarantee about the user's terminal emulator.
type wheelProgramFence struct{ ack chan struct{} }
type wheelFrameObservation struct {
	delta int
	at    time.Time
}
type transcriptWheelProgram struct {
	state  model
	frames chan wheelFrameObservation
	views  *atomic.Uint64
}

func (p transcriptWheelProgram) Init() tea.Cmd           { return nil }
func (p transcriptWheelProgram) wheelScope() wheelTarget { return wheelTargetOf(p.state) }
func (p transcriptWheelProgram) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if fence, ok := msg.(wheelProgramFence); ok {
		close(fence.ack)
		return p, nil
	}
	next, cmd := p.state.Update(msg)
	p.state = next.(model)
	if delta, ok := msg.(WheelDeltaMsg); ok {
		p.frames <- wheelFrameObservation{delta: delta.DeltaY, at: time.Now()}
	}
	return p, cmd
}
func (p transcriptWheelProgram) View() tea.View {
	p.views.Add(1)
	return p.state.View()
}

func TestWheelBurstReversalAndSilenceThroughTranscriptProgram(t *testing.T) {
	m := newModel()
	for i := 0; i < 2000; i++ {
		m.transcript = append(m.transcript, "history row")
	}
	m.width, m.height = 108, 36
	m.reflow()
	m.scrollTranscript(-2000)
	frames := make(chan wheelFrameObservation, 4096)
	views := new(atomic.Uint64)
	program := tea.NewProgram(transcriptWheelProgram{state: m, frames: frames, views: views},
		tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(),
		tea.WithWindowSize(108, 36), tea.WithFilter(NewWheelInput().Filter))
	done := make(chan error, 1)
	go func() { _, err := program.Run(); done <- err }()
	t.Cleanup(func() {
		program.Quit()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("program quit: %v", err)
			}
		case <-time.After(5 * time.Second):
			program.Kill()
			t.Error("program did not quit")
		}
	})
	fence := func() {
		t.Helper()
		ack := make(chan struct{})
		program.Send(wheelProgramFence{ack: ack})
		select {
		case <-ack:
		case <-time.After(5 * time.Second):
			t.Fatal("input fence was not consumed")
		}
	}
	fence() // Initial window/focus messages have settled before the burst.
	before := views.Load()
	const burst = 2000
	for i := 0; i < burst; i++ {
		program.Send(wheelEvent(tea.MouseWheelUp, 10, 10, 0))
	}
	program.Send(wheelEvent(tea.MouseWheelDown, 10, 10, 0))
	fence() // All old-direction reports and the reverse report were filtered.
	// Discard observations delivered before the fence. A pending old timer is
	// allowed to run, but it must now contain only the new direction.
	for len(frames) > 0 {
		<-frames
	}
	select {
	case frame := <-frames:
		if frame.delta != 1 {
			t.Fatalf("after reverse consumed an old-direction aggregate: %d", frame.delta)
		}
	case <-time.After(time.Second):
		// A very slow machine may have painted the new direction before the
		// fence. Silence is also valid; the deterministic tests pin its sum.
	}
	select {
	case frame := <-frames:
		t.Fatalf("stopped input kept scrolling: delta=%d", frame.delta)
	case <-time.After(80 * time.Millisecond):
	}
	acceptedViews := views.Load() - before
	if acceptedViews >= burst/4 {
		t.Fatalf("raw wheel burst was not coalesced before View: %d views / %d reports", acceptedViews, burst)
	}
	t.Logf("%d wheel reports + reverse -> %d logical View calls (not PTY latency)", burst, acceptedViews)
}
