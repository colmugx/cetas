package tui

import (
	"io"
	"reflect"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-native/internal/tui/composer"
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

func TestWheelInputUnknownOwnerFailsClosed(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelOpaqueModel{}
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 3, 0)))
	if first.DeltaY != -1 {
		t.Fatalf("first notch on unknown owner = %d, want -1", first.DeltaY)
	}
	if cmd := first.FlushCmd(); cmd != nil {
		t.Fatal("unknown owner armed a tail timer")
	}
	if clock.pending() != 0 {
		t.Fatal("unknown owner scheduled a tick")
	}
	second := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 3, 0)))
	if second.DeltaY != -1 {
		t.Fatalf("second notch on unknown owner = %d, want immediate -1", second.DeltaY)
	}
}

func TestWheelInputZeroValuePassesThroughWithoutPanicking(t *testing.T) {
	var w WheelInput
	key := tea.KeyPressMsg{Code: 'x'}
	if got := w.Filter(wheelTestModel(), key); got != tea.Msg(key) {
		t.Fatalf("zero-value filter rewrote a key: %#v", got)
	}
	// Without a clock the controller cannot coalesce; wheel reaches Update
	// untouched so the raw fallback still scrolls one row per notch.
	raw := wheelEvent(tea.MouseWheelUp, 0, 0, 0)
	if got := w.Filter(wheelTestModel(), raw); got != tea.Msg(raw) {
		t.Fatalf("zero-value filter rewrote a wheel notch: %#v", got)
	}
}

func TestWheelInputTargetChangeDropsPendingAndStalesTimer(t *testing.T) {
	mutations := []struct {
		name   string
		mutate func(*model)
	}{
		{"session", func(m *model) { m.session = "session-2" }},
		{"workspace", func(m *model) { m.surface.cwd = "/tmp/other-workspace" }},
		{"modal", func(m *model) { m.modal = "models" }},
		{"modal request", func(m *model) { m.modalRequestID = "request-2" }},
		{"search focus", func(m *model) { m.surface.searchOpen = true }},
		{"composer focus", func(m *model) { m.textarea.Focus() }},
		{"width", func(m *model) { m.width = 101 }},
		{"height", func(m *model) { m.height = 41 }},
	}
	for _, test := range mutations {
		t.Run(test.name, func(t *testing.T) {
			w, clock := fakeWheelInput(t)
			before := wheelTestModel()
			first := requireWheelDelta(t, w.Filter(before, wheelEvent(tea.MouseWheelUp, 3, 13, 0)))
			if first.Generation != 0 {
				t.Fatalf("initial generation = %d, want 0", first.Generation)
			}
			first.FlushCmd()
			if got := w.Filter(before, wheelEvent(tea.MouseWheelUp, 3, 13, 0)); got != nil {
				t.Fatalf("same-direction notch was not accumulated: %#v", got)
			}

			changed := before
			test.mutate(&changed)
			// A non-wheel message carries the new owner in the current model;
			// the model itself is returned unchanged.
			key := tea.KeyPressMsg{Code: '/', Text: "/"}
			if got := w.Filter(changed, key); got != key {
				t.Fatalf("key message changed: %#v -> %#v", key, got)
			}
			// The old timer still runs, but its message must not touch the
			// new document.
			if got := w.Filter(changed, clock.fire(t)); got != nil {
				t.Fatalf("stale timer delivered %#v to the new owner", got)
			}
			if clock.pending() != 0 {
				t.Fatal("stale timer re-armed itself")
			}
			// Old accumulated distance is gone: the first new-owner notch
			// paints immediately as exactly one row.
			next := requireWheelDelta(t, w.Filter(changed, wheelEvent(tea.MouseWheelUp, 8, 14, 0)))
			if next.DeltaY != -1 {
				t.Fatalf("new owner's first notch = %d, want -1 (old accumulation leaked)", next.DeltaY)
			}
			if next.Generation <= first.Generation {
				t.Fatalf("target generation did not advance: %d -> %d", first.Generation, next.Generation)
			}
		})
	}
}

func TestWheelInputStaleAcceptedAggregateCannotArmTimer(t *testing.T) {
	w, clock := fakeWheelInput(t)
	before := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(before, wheelEvent(tea.MouseWheelUp, 1, 1, 0)))
	changed := before
	changed.session = "other"
	if got := w.Filter(changed, wheelEvent(tea.MouseWheelUp, 1, 1, 0)); got == nil {
		t.Fatal("new target's first notch was not delivered")
	}
	if cmd := first.FlushCmd(); cmd != nil {
		t.Fatal("stale accepted aggregate armed a timer for the old target")
	}
	if clock.pending() != 0 {
		t.Fatal("stale accepted aggregate scheduled a timer")
	}
}

func TestWheelInputPassesNonWheelMessagesUnchanged(t *testing.T) {
	w, _ := fakeWheelInput(t)
	m := wheelTestModel()
	messages := []tea.Msg{
		tea.KeyPressMsg{Code: 'x', Text: "x"},
		tea.KeyReleaseMsg{Code: 'x'},
		tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 1, Y: 2}),
		tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: 1, Y: 2}),
		tea.MouseMotionMsg(tea.Mouse{X: 1, Y: 2}),
		tea.WindowSizeMsg{Width: 120, Height: 40},
		tea.QuitMsg{},
		// A wheel event that is not a scroll notch stays for the rest of the
		// filter chain instead of being swallowed.
		tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseButton(0xff), X: 1, Y: 2}),
	}
	for _, msg := range messages {
		if got := w.Filter(m, msg); !reflect.DeepEqual(got, msg) {
			t.Fatalf("filter rewrote %T: %#v -> %#v", msg, msg, got)
		}
	}
	// Private flush messages are never exposed to Update.
	if got := w.Filter(m, wheelFlushMsg{generation: 99, sequence: 99}); got != nil {
		t.Fatalf("private flush message leaked to Update: %#v", got)
	}
}

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

func TestWheelInputBarrierInvalidatesUnarmedAggregate(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 9, 12, 0)))
	barrier := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 9, Y: 12})
	if got := w.Filter(m, barrier); !reflect.DeepEqual(got, barrier) {
		t.Fatalf("click was rewritten: %#v -> %#v", barrier, got)
	}
	if cmd := first.FlushCmd(); cmd != nil {
		t.Fatal("aggregate accepted before the click armed a timer after it")
	}
	if clock.pending() != 0 {
		t.Fatal("pre-click aggregate scheduled a tail timer")
	}
}

func TestWheelInputPointerTargetChangeSplitsCoalescing(t *testing.T) {
	cases := []struct {
		name            string
		outside, inside tea.MouseWheelMsg
	}{
		{
			name:    "coordinates",
			outside: wheelEvent(tea.MouseWheelUp, 4, 10, 0),
			inside:  wheelEvent(tea.MouseWheelUp, 40, 18, 0),
		},
		{
			name:    "modifiers",
			outside: wheelEvent(tea.MouseWheelUp, 40, 18, 0),
			inside:  wheelEvent(tea.MouseWheelUp, 40, 18, tea.ModShift),
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			w, clock := fakeWheelInput(t)
			m := wheelTestModel()
			first := requireWheelDelta(t, w.Filter(m, test.outside))
			first.FlushCmd()
			if got := w.Filter(m, test.outside); got != nil {
				t.Fatalf("outside notch was not accumulated: %#v", got)
			}

			// Moving to another pointer target paints that target's first
			// notch immediately, without the outside-list distance attached.
			split := requireWheelDelta(t, w.Filter(m, test.inside))
			if split.DeltaY != -1 {
				t.Fatalf("new-target first notch = %d, want -1", split.DeltaY)
			}
			if !reflect.DeepEqual(wheelPointerOf(split.Mouse), wheelPointerOf(tea.Mouse(test.inside))) {
				t.Fatalf("new-target aggregate carried old coordinates: %#v", split.Mouse)
			}
			if split.Generation <= first.Generation {
				t.Fatalf("pointer target change did not advance generation: %d -> %d", first.Generation, split.Generation)
			}
			split.FlushCmd()

			// The old outside-list timer is stale; only the new target's own
			// accumulated notch is delivered by its tail.
			if got := w.Filter(m, clock.fire(t)); got != nil {
				t.Fatalf("old pointer target's timer delivered %#v", got)
			}
			if got := w.Filter(m, test.inside); got != nil {
				t.Fatalf("inside notch was not accumulated: %#v", got)
			}
			tail := requireWheelDelta(t, w.Filter(m, clock.fire(t)))
			if tail.DeltaY != -1 {
				t.Fatalf("inside tail = %d, want -1", tail.DeltaY)
			}
			if !reflect.DeepEqual(wheelPointerOf(tail.Mouse), wheelPointerOf(tea.Mouse(test.inside))) {
				t.Fatalf("inside tail carried old coordinates: %#v", tail.Mouse)
			}
		})
	}
}

func TestWheelInputMotionIsNotAHoverBarrier(t *testing.T) {
	w, clock := fakeWheelInput(t)
	m := wheelTestModel()
	first := requireWheelDelta(t, w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 14, 0)))
	first.FlushCmd()
	if got := w.Filter(m, wheelEvent(tea.MouseWheelUp, 3, 14, 0)); got != nil {
		t.Fatalf("notch was not accumulated: %#v", got)
	}
	motion := tea.MouseMotionMsg(tea.Mouse{X: 50, Y: 2})
	if got := w.Filter(m, motion); !reflect.DeepEqual(got, motion) {
		t.Fatalf("motion message changed: %#v -> %#v", motion, got)
	}
	// Pointer motion alone neither throttles nor re-targets the pending wheel;
	// the aggregate keeps the coordinates its notches were gathered at.
	tail := requireWheelDelta(t, w.Filter(m, clock.fire(t)))
	if tail.DeltaY != -1 || tail.Mouse.X != 3 || tail.Mouse.Y != 14 {
		t.Fatalf("motion rewrote the pending wheel: %#v", tail)
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
