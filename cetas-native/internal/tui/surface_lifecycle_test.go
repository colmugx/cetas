package tui

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func TestNativeKeyedStatusRendersExpireIndependently(t *testing.T) {
	m := newModel()
	for _, raw := range []string{
		`{"type":"ui.render","render":{"slot":"status","key":"build","title":"Build","ttl_ms":100,"body":{"type":"progress","current":0.5}}}`,
		`{"type":"ui.render","render":{"slot":"status","key":"other","body":{"type":"text","text":"other stays"}}}`,
	} {
		m.applyEvent(event(raw))
	}
	m.reflow()
	screen := ansi.Strip(m.View().Content)
	if !strings.Contains(screen, "Build · 50%") || !strings.Contains(screen, "other stays") {
		t.Fatalf("independent status renders lost: %s", screen)
	}
	next, _ := m.Update(clockTick(time.Now().Add(time.Second)))
	m = next.(model)
	screen = ansi.Strip(m.View().Content)
	if strings.Contains(screen, "Build · 50%") || !strings.Contains(screen, "other stays") {
		t.Fatalf("status TTL not scoped to key: %s", screen)
	}
}

func TestSessionRetirementCancelsAsksAndDropsEphemeralState(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.session = "one"
	m.applyEvent(event(`{"type":"ui.request","session_id":"one","request_id":"a","kind":"confirm","prompt":"old ask"}`))
	m.applyEvent(event(`{"type":"ui.request","session_id":"one","request_id":"b","kind":"input","prompt":"old queued ask"}`))
	m.applyEvent(event(`{"type":"ui.render","session_id":"one","render":{"slot":"widget","key":"w","body":{"type":"text","text":"old widget"}}}`))
	m.applyEvent(event(`{"type":"tool.args_delta","session_id":"one","index":0,"id":"old-call","name":"read","delta":"{}"}`))
	next, _ := m.Update(commandResult{name: "switch_session", payload: json.RawMessage(`{"session_id":"two","status":"ready"}`)})
	m = next.(model)
	if len(m.pendingUI) != 0 || m.modalRequestID != "" || len(m.fragments) != 0 || len(m.surface.widgets) != 0 {
		t.Fatal("presentation crossed session boundary")
	}
}
