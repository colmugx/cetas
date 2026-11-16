package tui

import (
	"encoding/json"
	"testing"

	"github.com/colmugx/cetas/cetas-go/internal/wire"
)

func cursorEvent(raw string) wire.Event { return wire.Event{Raw: json.RawMessage(raw)} }

func TestSessionEventCursorContiguousDuplicateAndGap(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "s-1"

	m.applyEvent(cursorEvent(`{"type":"session.snapshot","session_id":"s-1","runtime_epoch":"epoch-a","cursor":4,"high_water_cursor":4,"cursor_advance":false}`))
	if m.runtimeEpoch != "epoch-a" || m.eventCursor != 4 || m.eventResyncPending {
		t.Fatalf("snapshot did not establish baseline: epoch=%q cursor=%d pending=%v", m.runtimeEpoch, m.eventCursor, m.eventResyncPending)
	}

	m.applyEvent(cursorEvent(`{"type":"turn.accepted","session_id":"s-1","runtime_epoch":"epoch-a","cursor":5,"cursor_advance":true,"turn_id":"t-1"}`))
	if m.eventCursor != 5 || m.eventResyncPending {
		t.Fatalf("contiguous event not accepted: cursor=%d pending=%v", m.eventCursor, m.eventResyncPending)
	}

	m.applyEvent(cursorEvent(`{"type":"turn.accepted","session_id":"s-1","runtime_epoch":"epoch-a","cursor":5,"cursor_advance":true,"turn_id":"t-1"}`))
	if m.eventCursor != 5 || m.eventResyncPending {
		t.Fatalf("duplicate event changed cursor: cursor=%d pending=%v", m.eventCursor, m.eventResyncPending)
	}

	m.applyEvent(cursorEvent(`{"type":"assistant.text_delta","session_id":"s-1","runtime_epoch":"epoch-a","cursor":7,"cursor_advance":true,"delta":"lost predecessor"}`))
	if m.eventCursor != 5 || !m.eventResyncPending || m.streaming != "" {
		t.Fatalf("gap was not rejected: cursor=%d pending=%v streaming=%q", m.eventCursor, m.eventResyncPending, m.streaming)
	}
}

func TestSessionEventCursorIgnoresOtherSessionsAndUnicast(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "s-1"
	m.applyEvent(cursorEvent(`{"type":"session.snapshot","session_id":"s-1","runtime_epoch":"epoch-a","cursor":3,"high_water_cursor":3}`))

	m.applyEvent(cursorEvent(`{"type":"turn.accepted","session_id":"s-2","runtime_epoch":"epoch-a","cursor":1,"cursor_advance":true,"turn_id":"t-2"}`))
	m.applyEvent(cursorEvent(`{"type":"connection.ready","session_id":"s-1","runtime_epoch":"epoch-a","cursor":3,"cursor_advance":false}`))
	if m.eventCursor != 3 || m.eventResyncPending {
		t.Fatalf("other session/unicast changed cursor: cursor=%d pending=%v", m.eventCursor, m.eventResyncPending)
	}
}

func TestSessionEventCursorRuntimeRestartRequiresSnapshot(t *testing.T) {
	m := newModel()
	defer m.Close()
	m.session = "s-1"
	m.applyEvent(cursorEvent(`{"type":"session.snapshot","session_id":"s-1","runtime_epoch":"epoch-a","cursor":9,"high_water_cursor":9}`))
	m.applyEvent(cursorEvent(`{"type":"turn.started","session_id":"s-1","runtime_epoch":"epoch-b","cursor":1,"cursor_advance":true}`))
	if !m.eventResyncPending || m.runtimeEpoch != "epoch-a" {
		t.Fatalf("new epoch event was not held for snapshot: epoch=%q pending=%v", m.runtimeEpoch, m.eventResyncPending)
	}
	m.applyEvent(cursorEvent(`{"type":"session.snapshot","session_id":"s-1","runtime_epoch":"epoch-b","cursor":1,"high_water_cursor":1}`))
	if m.runtimeEpoch != "epoch-b" || m.eventCursor != 1 || !m.eventResyncPending {
		t.Fatalf("restart snapshot did not request replay: epoch=%q cursor=%d pending=%v", m.runtimeEpoch, m.eventCursor, m.eventResyncPending)
	}
}
