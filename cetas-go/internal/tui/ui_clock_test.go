package tui

import (
	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
	"testing"
	"time"
)

func TestExpiredWidgetReturnsUIToSleep(t *testing.T) {
	m := newModel()
	next, cmd := m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"ui.render","render":{"slot":"widget","key":"test","body":{"type":"text","text":"temporary"},"ttl_ms":10}}`)}})
	m = next.(model)
	if cmd == nil || m.clockDue.IsZero() {
		t.Fatal("widget expiry was not scheduled")
	}
	gen := m.clockGeneration
	deadline := m.clockDue.Add(time.Millisecond)
	next, cmd = m.Update(scheduledUITick{generation: gen, at: deadline})
	m = next.(model)
	if len(m.surface.widgets) != 0 || cmd != nil {
		t.Fatal("expired widget kept an idle frame loop alive")
	}
}
func TestStaleAnimationCannotReviveAfterTurnEnds(t *testing.T) {
	m := newModel()
	m.running = true
	next, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m = next.(model)
	stale := scheduledUITick{generation: m.clockGeneration, at: time.Now().Add(time.Second)}
	next, _ = m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"turn.completed","text":"done"}`)}})
	m = next.(model)
	frame := m.surface.frame
	next, cmd := m.Update(stale)
	m = next.(model)
	if cmd != nil || m.surface.frame != frame {
		t.Fatal("stale frame restarted animation after completion")
	}
}

func TestColdReplayIndexDeadlineWakesIdleUI(t *testing.T) {
	m := newModel()
	m.session = "s-1"
	m.host = &testHost{}
	m.startPagedReplay()
	if !m.replayIndexPending {
		t.Fatal("fixture: replay index not pending")
	}
	want := m.replayIndexSince.Add(replayIndexTimeout + time.Millisecond)
	due := m.nextUIWake(time.Now())
	if due.IsZero() || !due.Equal(want) {
		t.Fatalf("idle replay index must schedule its timeout: got %v, want %v", due, want)
	}
	m.replayIndexPending = false
	if got := m.nextUIWake(time.Now()); !got.IsZero() {
		t.Fatalf("settled replay index kept the idle clock awake: %v", got)
	}
}
