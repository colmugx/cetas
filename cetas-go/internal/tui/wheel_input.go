package tui

import (
	"time"

	tea "charm.land/bubbletea/v2"
)

// wheelInterval is the coalescing cadence at the input boundary, matching the
// target frame rate (≈60 Hz). It is not scroll inertia: displacement is never
// interpolated or accelerated, only gathered before the next Update/View.
const wheelInterval = 16 * time.Millisecond

// wheelTarget names the surface that currently owns wheel input. A change in
// any field discards the unsent accumulation and makes every in-flight tail
// timer stale, so pending wheel distance can never land in another session,
// modal, focused surface or window geometry. unknownOwner marks a model whose
// owner cannot be read: coalescing is disabled for it instead of pretending
// the owner never changes.
type wheelTarget struct {
	session          string
	workspace        string
	modal            string
	modalRequest     string
	searchOpen       bool
	composerFocused  bool
	width, height    int
	pickerOpen       bool
	pickerEpoch      uint64
	pickerGeneration int
	unknownOwner     bool
}

// wheelScopeProvider lets the presentation model define its own wheel owner.
// The default implementation below already covers the fields native owns; the
// interface keeps the seam package-private if the model grows a richer owner.
type wheelScopeProvider interface {
	wheelScope() wheelTarget
}

// wheelTargetOf reads the owning surface from Bubble Tea's current model. The
// filter runs on the event loop just before Update, so this is the pre-update
// state; a key or resize that changes the owner is observed on the next
// message, before any pending delta can be delivered.
func wheelTargetOf(m tea.Model) wheelTarget {
	if m == nil {
		return wheelTarget{}
	}
	if provider, ok := m.(wheelScopeProvider); ok {
		return provider.wheelScope()
	}
	switch current := m.(type) {
	case model:
		return wheelTarget{
			session:          current.session,
			workspace:        current.surface.cwd,
			modal:            current.modal,
			modalRequest:     current.modalRequestID,
			searchOpen:       current.surface.searchOpen,
			composerFocused:  current.textarea.Focused(),
			width:            current.width,
			height:           current.height,
			pickerOpen:       current.sessionPicker.open,
			pickerEpoch:      current.sessionPickerEpoch,
			pickerGeneration: current.sessionPicker.panel.Generation,
		}
	case *model:
		if current == nil {
			return wheelTarget{unknownOwner: true}
		}
		return wheelTarget{
			session:          current.session,
			workspace:        current.surface.cwd,
			modal:            current.modal,
			modalRequest:     current.modalRequestID,
			searchOpen:       current.surface.searchOpen,
			composerFocused:  current.textarea.Focused(),
			width:            current.width,
			height:           current.height,
			pickerOpen:       current.sessionPicker.open,
			pickerEpoch:      current.sessionPickerEpoch,
			pickerGeneration: current.sessionPicker.panel.Generation,
		}
	default:
		// A wrapper model the coalescer cannot read. Treating it as a static
		// owner would let a pending tail cross a boundary it cannot see, so
		// mark it unknown and fail closed in observe.
		return wheelTarget{unknownOwner: true}
	}
}

// wheelPointer is the pointer identity of one coalescing group. Coordinates or
// modifiers changing means the wheel moved to another target (for example from
// outside a list to inside it), so the previous group's unsent delta is
// discarded instead of being reattached to the new last sample.
type wheelPointer struct {
	x, y int
	mod  tea.KeyMod
}

func wheelPointerOf(mouse tea.Mouse) wheelPointer {
	return wheelPointer{x: mouse.X, y: mouse.Y, mod: mouse.Mod}
}

// wheelToken ties an accepted aggregate to the target generation and to the
// one coalescing window it was emitted from.
type wheelToken struct {
	generation uint64
	sequence   uint64
}

// wheelFlushMsg is the private trailing-timer message. It carries only
// immutable identifiers: the timer goroutine never reads or mutates the
// controller, so Bubble Tea's value-copied model cannot race it.
type wheelFlushMsg struct {
	generation uint64
	sequence   uint64
}

// WheelDeltaMsg is the app-owned aggregate delivered through tea.WithFilter.
// Each accepted message is worth exactly one Update/View; wheel notches that
// arrive inside the open coalescing window bypass both. DeltaY is the signed
// notch count (wheel up -1, down +1); horizontal notches are discarded at the
// boundary because no surface routes them. Mouse is the most recent sample of
// the current pointer group so routing keeps that group's coordinates,
// modifiers and pointer location. Generation advances when the owning target
// or pointer group changes, so an aggregate from an earlier surface can be
// recognized and discarded.
type WheelDeltaMsg struct {
	Mouse      tea.Mouse
	DeltaY     int
	Generation uint64

	controller *WheelInput
	token      wheelToken
}

// FlushCmd returns the single trailing flush command for this accepted
// aggregate; return it from Update (`return m, msg.FlushCmd()`). If input then
// stops, the timer drains whatever accumulated and the next idle timer ends
// the chain: at most one timer is armed at a time, and an orphaned timer left
// by a barrier is stale by sequence, so timers can never pile up or tick
// forever. It returns nil for a stale aggregate, a nil controller or when a
// timer is already pending.
func (msg WheelDeltaMsg) FlushCmd() tea.Cmd {
	w := msg.controller
	if w == nil || !w.scoped || msg.token != w.accepted || w.timerSeq != 0 {
		return nil
	}
	delay := w.interval - w.now().Sub(w.acceptedAt)
	if delay < 0 {
		delay = 0
	}
	w.nextTimerSeq++
	sequence := w.nextTimerSeq
	w.timerSeq = sequence
	generation := msg.token.generation
	return w.tick(delay, func(time.Time) tea.Msg {
		return wheelFlushMsg{generation: generation, sequence: sequence}
	})
}

// WheelInput coalesces mouse-wheel notches at the Bubble Tea input boundary.
// Install Filter with tea.WithFilter; the model only has to handle
// WheelDeltaMsg and return its FlushCmd.
//
// The controller is intentionally mutable shared state, but only the Bubble
// Tea event loop touches it: Filter runs there before Update, and FlushCmd is
// called from Update there. Timer callbacks capture immutable values and never
// read this struct, so model value copies are safe.
type WheelInput struct {
	now      func() time.Time
	tick     func(time.Duration, func(time.Time) tea.Msg) tea.Cmd
	interval time.Duration

	generation uint64
	target     wheelTarget
	scoped     bool

	accumY     int
	accumMouse tea.Mouse
	accum      bool
	pointer    wheelPointer

	accepted   wheelToken
	acceptedAt time.Time
	acceptSeq  uint64

	timerSeq     uint64
	nextTimerSeq uint64
}

// NewWheelInput builds the process-wide wheel coalescer for one Bubble Tea
// program. Use the same instance for tea.WithFilter and nowhere else.
func NewWheelInput() *WheelInput {
	return newWheelInput(time.Now, tea.Tick, wheelInterval)
}

func newWheelInput(now func() time.Time, tick func(time.Duration, func(time.Time) tea.Msg) tea.Cmd, interval time.Duration) *WheelInput {
	if interval <= 0 {
		interval = wheelInterval
	}
	return &WheelInput{now: now, tick: tick, interval: interval}
}

// Filter implements the tea.WithFilter signature. It preserves every message
// unchanged except wheel notches it coalesces and its own private flush
// messages. The first notch of a stream (or of a new target) is delivered
// immediately; same-direction notches inside the open window accumulate and
// return nil so they cost no Update/View at all; the trailing timer drains the
// accumulated distance after input stops. Opposite-direction input clears the
// unsent old-direction delta before it is added, so a reversal paints the new
// direction within one frame instead of taking one more stale step.
//
// Non-wheel barriers (key press/release, pointer press/release, window resize)
// discard unsent wheel before the selection or owner can change, but the
// barrier itself is returned untouched and is never throttled.
func (w *WheelInput) Filter(m tea.Model, msg tea.Msg) tea.Msg {
	if w == nil || w.now == nil || w.tick == nil {
		// A zero-value controller has no clock: pass everything through
		// instead of panicking. Coalescing requires NewWheelInput.
		return msg
	}
	w.observe(m)
	switch msg := msg.(type) {
	case wheelFlushMsg:
		return w.flush(msg)
	case tea.MouseWheelMsg:
		return w.wheel(msg)
	default:
		if wheelBarrier(msg) {
			w.dropPending(false)
		}
		return msg
	}
}

// wheelBarrier reports messages after which a pending wheel tail must not
// move the document: a press/release can select or change the owner, a key can
// navigate, and a resize invalidates the rows the delta was gathered against.
func wheelBarrier(msg tea.Msg) bool {
	switch msg.(type) {
	case tea.KeyPressMsg, tea.KeyReleaseMsg,
		tea.MouseClickMsg, tea.MouseReleaseMsg,
		tea.WindowSizeMsg:
		return true
	}
	return false
}

// dropPending clears the unsent group and makes its tail timer stale through
// the cleared timer sequence. invalidate additionally bumps the generation for
// a real owner change (session, modal, focus, window or pointer target).
func (w *WheelInput) dropPending(invalidate bool) {
	if invalidate {
		w.generation++
	}
	w.accumY = 0
	w.accumMouse = tea.Mouse{}
	w.accum = false
	w.pointer = wheelPointer{}
	w.accepted = wheelToken{}
	w.acceptedAt = time.Time{}
	w.timerSeq = 0
}

// observe switches targets. Pending distance from the old owner is dropped
// rather than delivered to the new document, and the generation bump invalidates
// any tail timer still in flight. An unreadable owner fails closed: every
// notch is delivered immediately rather than coalesced against an owner the
// filter cannot verify.
func (w *WheelInput) observe(m tea.Model) {
	target := wheelTargetOf(m)
	if target.unknownOwner {
		w.dropPending(true)
		w.scoped = false
		return
	}
	if !w.scoped {
		w.scoped = true
		w.target = target
		return
	}
	if target == w.target {
		return
	}
	w.target = target
	w.dropPending(true)
}

func (w *WheelInput) wheel(msg tea.MouseWheelMsg) tea.Msg {
	_, dy, ok := wheelNotches(msg.Button)
	if !ok {
		// Not a scrolling wheel button: leave it for the rest of the chain.
		return msg
	}
	if dy == 0 {
		// Horizontal notches have no surface in this app. Discarding them at
		// the boundary is cheaper than coalescing an axis nothing routes.
		return nil
	}
	mouse := tea.Mouse(msg)
	if w.timerSeq != 0 && wheelPointerOf(mouse) != w.pointer {
		// The pointer moved to another target inside the window. Discard the
		// old target's unsent distance and paint this target's first notch now
		// instead of combining it with an outside-list lastMouse.
		w.dropPending(true)
	}
	if w.timerSeq == 0 {
		// No tail timer is open, so this is the first notch of a stream; paint
		// it now with zero filter-added latency. A defensive merge preserves
		// unsent distance if a previous window was never armed.
		if w.accum {
			if wheelOpposite(dy, w.accumY) {
				w.accumY = 0
			}
			dy += w.accumY
			w.accumY = 0
			w.accum = false
		}
		if dy == 0 {
			return nil
		}
		return w.accept(mouse, dy)
	}
	// Inside the single open window: drop unsent old-direction distance on a
	// sign flip, then accumulate the new direction for the trailing frame.
	if wheelOpposite(dy, w.accumY) {
		w.accumY = 0
	}
	w.accumY += dy
	w.accumMouse = mouse
	w.accum = true
	return nil
}

func (w *WheelInput) accept(mouse tea.Mouse, dy int) WheelDeltaMsg {
	w.acceptSeq++
	token := wheelToken{generation: w.generation, sequence: w.acceptSeq}
	w.accepted = token
	w.acceptedAt = w.now()
	w.pointer = wheelPointerOf(mouse)
	return WheelDeltaMsg{
		Mouse:      mouse,
		DeltaY:     dy,
		Generation: token.generation,
		controller: w,
		token:      token,
	}
}

func (w *WheelInput) flush(msg wheelFlushMsg) tea.Msg {
	if msg.generation != w.generation || msg.sequence == 0 || msg.sequence != w.timerSeq {
		// A timer from a previous target (or a superseded window) must not
		// touch the new document.
		return nil
	}
	w.timerSeq = 0
	if !w.accum || w.accumY == 0 {
		// Silence: the last timer of the stream ends here. No aggregate is
		// emitted, so no new timer is armed and there is no permanent tick.
		w.accumY = 0
		w.accum = false
		return nil
	}
	mouse := w.accumMouse
	dy := w.accumY
	w.accumY = 0
	w.accum = false
	return w.accept(mouse, dy)
}

func wheelNotches(button tea.MouseButton) (dx, dy int, ok bool) {
	switch button {
	case tea.MouseWheelUp:
		return 0, -1, true
	case tea.MouseWheelDown:
		return 0, 1, true
	case tea.MouseWheelLeft:
		return -1, 0, true
	case tea.MouseWheelRight:
		return 1, 0, true
	default:
		return 0, 0, false
	}
}

func wheelOpposite(a, b int) bool {
	return (a > 0 && b < 0) || (a < 0 && b > 0)
}
