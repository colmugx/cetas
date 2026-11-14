package tui

import (
	"io"
	"reflect"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-go/internal/tui/composer"
)

// fakeWheelClock keeps the coalescing window deterministic: FlushCmd records
// the timer instead of sleeping, and fire delivers the private timer message
// through the filter exactly as Bubble Tea would after the delay.
type fakeWheelClock struct {
	now   time.Time
	ticks []fakeWheelTick
}

type fakeWheelTick struct {
	delay time.Duration
	fn    func(time.Time) tea.Msg
}

func newFakeWheelClock() *fakeWheelClock {
	return &fakeWheelClock{now: time.Unix(1_700_000_000, 0)}
}

func (c *fakeWheelClock) Now() time.Time { return c.now }

func (c *fakeWheelClock) Tick(delay time.Duration, fn func(time.Time) tea.Msg) tea.Cmd {
	c.ticks = append(c.ticks, fakeWheelTick{delay: delay, fn: fn})
	return func() tea.Msg { return nil }
}

func (c *fakeWheelClock) pending() int { return len(c.ticks) }

func (c *fakeWheelClock) fire(t *testing.T) tea.Msg {
	t.Helper()
	if len(c.ticks) == 0 {
		t.Fatal("no wheel tail timer is pending")
	}
	tick := c.ticks[0]
	c.ticks = c.ticks[1:]
	c.now = c.now.Add(tick.delay)
	return tick.fn(c.now)
}

func fakeWheelInput(t *testing.T) (*WheelInput, *fakeWheelClock) {
	t.Helper()
	clock := newFakeWheelClock()
	return newWheelInput(clock.Now, clock.Tick, wheelInterval), clock
}

func wheelEvent(button tea.MouseButton, x, y int, mod tea.KeyMod) tea.MouseWheelMsg {
	return tea.MouseWheelMsg(tea.Mouse{Button: button, X: x, Y: y, Mod: mod})
}

func wheelTestModel() model {
	// A real composer keeps focus state addressable without building the whole
	// presentation model for pure input-boundary tests.
	return model{width: 80, height: 24, textarea: composer.New()}
}

func requireWheelDelta(t *testing.T, msg tea.Msg) WheelDeltaMsg {
	t.Helper()
	delta, ok := msg.(WheelDeltaMsg)
	if !ok {
		t.Fatalf("wheel filter returned %#v, want WheelDeltaMsg", msg)
	}
	return delta
}

func TestWheelInputFirstNotchIsOneRowAndImmediate(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	delta := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 7, 11, tea.ModShift)))
	if delta.DeltaY != -1 {
		t.Fatalf("first notch delta = %d, want -1", delta.DeltaY)
	}
	if delta.Mouse.X != 7 || delta.Mouse.Y != 11 || delta.Mouse.Mod != tea.ModShift {
		t.Fatalf("first notch lost coordinates/modifiers: %#v", delta.Mouse)
	}
	if clock.pending() != 0 {
		t.Fatal("the trailing timer was armed before the aggregate was accepted")
	}
	if cmd := delta.FlushCmd(); cmd == nil {
		t.Fatal("accepted aggregate did not provide a trailing flush command")
	}
	if clock.pending() != 1 || clock.ticks[0].delay != wheelInterval {
		t.Fatalf("trailing timer = %#v, want one %s tick", clock.ticks, wheelInterval)
	}
	if cmd := delta.FlushCmd(); cmd != nil {
		t.Fatal("a second accepted command armed a second tail timer")
	}
	if clock.pending() != 1 {
		t.Fatalf("pending tail timers = %d, want one", clock.pending())
	}
	// The accepted message starts a window; silence ends it without output.
	if got := w.Filter(m, clock.fire(t)); got != nil {
		t.Fatalf("idle tail timer emitted %#v", got)
	}
	if clock.pending() != 0 {
		t.Fatal("idle tail timer scheduled a permanent tick")
	}
}

func TestWheelInputSameDirectionBurstIsHiddenUntilTrailingFlush(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 5, 24, tea.ModAlt)))
	first.FlushCmd()
	for i := 0; i < 4; i++ {
		got := w.Filter(m, wheelEvent(tea.MouseWheelUp, 5, 24, tea.ModAlt))
		if got != nil {
			t.Fatalf("burst notch %d reached Update/View: %#v", i, got)
		}
	}
	if clock.pending() != 1 {
		t.Fatalf("burst has %d pending timers, want one", clock.pending())
	}
	tail := requireWheelDelta(t, w.Filter(m, clock.fire(t)))
	if tail.DeltaY != -4 {
		t.Fatalf("trailing flush delta = %d, want -4", tail.DeltaY)
	}
	if tail.Mouse.X != 5 || tail.Mouse.Y != 24 || tail.Mouse.Mod != tea.ModAlt {
		t.Fatalf("trailing flush lost the last sample: %#v", tail.Mouse)
	}
	if cmd := tail.FlushCmd(); cmd == nil {
		t.Fatal("trailing aggregate did not provide its last timer")
	}
	if got := w.Filter(m, clock.fire(t)); got != nil {
		t.Fatalf("last idle timer emitted %#v", got)
	}
	if clock.pending() != 0 {
		t.Fatal("tail chain did not terminate after silence")
	}
}

func TestWheelInputReversalDropsUnpresentedOldDirection(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 4, 30, 0)))
	if first.DeltaY != -1 {
		t.Fatalf("first notch = %d, want -1", first.DeltaY)
	}
	first.FlushCmd()
	if got := w.Filter(m, wheelEvent(tea.MouseWheelUp, 4, 30, 0)); got != nil {
		t.Fatalf("second upward notch was not accumulated: %#v", got)
	}
	if got := w.Filter(m, wheelEvent(tea.MouseWheelDown, 4, 30, 0)); got != nil {
		t.Fatalf("first reversed notch was not accumulated: %#v", got)
	}
	if got := w.Filter(m, wheelEvent(tea.MouseWheelDown, 4, 30, 0)); got != nil {
		t.Fatalf("second reversed notch was not accumulated: %#v", got)
	}
	reversed := requireWheelDelta(t, w.Filter(m, clock.fire(t)))
	if reversed.DeltaY != 2 {
		t.Fatalf("reversal aggregate = %d, want +2 (old up distance discarded)", reversed.DeltaY)
	}
	if reversed.Generation != first.Generation {
		t.Fatalf("reversal changed target generation: %d -> %d", first.Generation, reversed.Generation)
	}
	reversed.FlushCmd()
	if got := w.Filter(m, clock.fire(t)); got != nil {
		t.Fatalf("post-reversal idle timer emitted %#v", got)
	}
	// After the window closes, a new direction paints immediately in one row.
	next := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelDown, 4, 30, 0)))
	if next.DeltaY != 1 {
		t.Fatalf("first notch after reversal = %d, want +1", next.DeltaY)
	}
}

func TestWheelInputHorizontalNotchesAreDroppedAtTheBoundary(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	for i, button := range []tea.MouseButton{tea.MouseWheelLeft, tea.MouseWheelRight} {
		if got := w.Filter(m, wheelEvent(button, 1, 2, 0)); got != nil {
			t.Fatalf("horizontal notch %d reached Update/View: %#v", i, got)
		}
	}
	if clock.pending() != 0 {
		t.Fatal("a discarded horizontal notch armed a tail timer")
	}
	// A dropped horizontal notch must not poison the vertical stream either.
	delta := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 1, 2, 0)))
	if delta.DeltaY != -1 {
		t.Fatalf("vertical notch after horizontal drop = %d, want -1", delta.DeltaY)
	}
}

// wheelOpaqueModel is a wrapper shape the coalescer cannot read. Coalescing
// must fail closed for it: every notch is delivered immediately instead of
// gathering distance against an owner the filter cannot verify.
type wheelOpaqueModel struct{ model }

func TestWheelInputBarriersDropUnsentWheelWithoutRewritingInput(t *testing.T) {
	barriers := []struct {
		name string
		msg  tea.Msg
	}{
		{"key press", tea.KeyPressMsg{Code: 'j', Text: "j"}},
		{"key release", tea.KeyReleaseMsg{Code: 'j'}},
		{"mouse press", tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 9, Y: 12})},
		{"mouse release", tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: 9, Y: 12})},
		{"window resize", tea.WindowSizeMsg{Width: 120, Height: 40}},
	}
	for _, barrier := range barriers {
		t.Run(barrier.name, func(t *testing.T) {
			w, clock := fakeWheelInput(t)
			m := wheelTestModel()
			first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 9, 12, 0)))
			first.FlushCmd()
			if got := w.Filter(m, wheelEvent(tea.MouseWheelUp, 9, 12, 0)); got != nil {
				t.Fatalf("pending notch was not accumulated: %#v", got)
			}

			// The barrier itself must reach Update untouched.
			if got := w.Filter(m, barrier.msg); !reflect.DeepEqual(got, barrier.msg) {
				t.Fatalf("barrier was rewritten: %#v -> %#v", barrier.msg, got)
			}
			// Its old tail timer must not move the document after the press,
			// key or resize.
			if got := w.Filter(m, clock.fire(t)); got != nil {
				t.Fatalf("pre-barrier tail delivered %#v", got)
			}
			if clock.pending() != 0 {
				t.Fatal("pre-barrier tail re-armed itself")
			}
			next := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 9, 12, 0)))
			if next.DeltaY != -1 {
				t.Fatalf("post-barrier notch = %d, want -1 (pre-barrier distance leaked)", next.DeltaY)
			}
			if next.Generation != first.Generation {
				t.Fatalf("same-target barrier changed generation: %d -> %d", first.Generation, next.Generation)
			}
		})
	}
}

// wheelProgramModel exercises the real Bubble Tea event loop: the product
// model only has to handle the aggregate and return its tail command.
type wheelProgramModel struct {
	applied chan WheelDeltaMsg
	resized chan struct{}
	totalY  int
}

func (m wheelProgramModel) Init() tea.Cmd { return nil }

func (m wheelProgramModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := msg.(tea.WindowSizeMsg); ok {
		// Bubble Tea delivers an initial resize before input starts. Let the
		// test wait for it so the resize barrier cannot race the wheel burst.
		select {
		case m.resized <- struct{}{}:
		default:
		}
		return m, nil
	}
	delta, ok := msg.(WheelDeltaMsg)
	if !ok {
		return m, nil
	}
	m.totalY += delta.DeltaY
	m.applied <- delta
	return m, delta.FlushCmd()
}

func (m wheelProgramModel) View() tea.View { return tea.NewView("") }

func TestWheelInputFilterIsWiredThroughBubbleTeaProgram(t *testing.T) {
	wheel := NewWheelInput()
	programModel := wheelProgramModel{
		applied: make(chan WheelDeltaMsg, 16),
		resized: make(chan struct{}, 1),
	}
	program := tea.NewProgram(
		programModel,
		tea.WithInput(nil),
		tea.WithOutput(io.Discard),
		tea.WithoutRenderer(),
		tea.WithWindowSize(80, 24),
		tea.WithFilter(wheel.Filter),
	)
	run := make(chan error, 1)
	go func() {
		_, err := program.Run()
		run <- err
	}()
	select {
	case <-programModel.resized:
	case err := <-run:
		t.Fatalf("program exited before its initial resize: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("program did not deliver its initial resize")
	}

	const notches = 5
	for i := 0; i < notches; i++ {
		program.Send(wheelEvent(tea.MouseWheelUp, 12, 24, tea.ModShift))
	}
	total := 0
	timeout := time.After(5 * time.Second)
	for total > -notches {
		select {
		case delta := <-programModel.applied:
			if delta.DeltaY > 0 {
				t.Fatalf("wheel reached the program with non-up delta %d", delta.DeltaY)
			}
			total += delta.DeltaY
		case err := <-run:
			t.Fatalf("program exited before the tail flush: %v", err)
		case <-timeout:
			t.Fatalf("program delivered %d of %d wheel rows", -total, notches)
		}
	}
	program.Send(tea.QuitMsg{})
	select {
	case err := <-run:
		if err != nil {
			t.Fatalf("program run: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("program did not quit")
	}
}
