package tui

import (
	"encoding/json"
	"testing"
)

func TestLatePickerReplyCannotStealFIFOQuestionFocus(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"Approve?"}`))
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-2","kind":"input","prompt":"Details?"}`))
	next, _ := m.Update(commandResult{name: "sessions", payload: json.RawMessage(`{"sessions":[{"id":"s","title":"Saved session"}]}`)})
	m = next.(model)
	if m.modal != "confirm" || m.modalRequestID != "u-1" {
		t.Fatal("late picker stole approval focus")
	}
	m.dismissUI("u-1")
	if m.modalRequestID != "u-2" {
		t.Fatal("deferred picker overtook queued ask")
	}
	m.dismissUI("u-2")
	next, cmd := m.Update(struct{}{})
	m = next.(model)
	if cmd == nil {
		t.Fatal("completed picker result was silently lost")
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	if m.modal != "sessions" || len(m.modalItems) != 1 {
		t.Fatal("deferred picker did not open after asks")
	}
}
