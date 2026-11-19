package harness

import (
	"encoding/json"
	"testing"
)

// Fanout must not broadcast one Session's working or deltas to a different
// Session, nor block the owner when an observer stops reading.
func TestSessionBridgeFanoutIsolatedAndBounded(t *testing.T) {
	h := &Host{streams: make(map[uint64]sessionStream)}
	a := make(chan json.RawMessage, 1)
	b := make(chan json.RawMessage, 1)
	h.streams[1] = sessionStream{sessionID: "session-a", frames: a}
	h.streams[2] = sessionStream{sessionID: "session-b", frames: b}
	h.publishSessionFrame([]byte(`{"type":"turn.accepted","session_id":"session-a","runtime_epoch":"epoch","cursor":1,"cursor_advance":true}`))
	select {
	case raw := <-a:
		var event struct{ Type string `json:"type"` }
		if err := json.Unmarshal(raw, &event); err != nil || event.Type != "turn.accepted" {
			t.Fatalf("corrupted working event: %s %v", raw, err)
		}
	default:
		t.Fatal("owner did not publish working immediately")
	}
	select {
	case <-b:
		t.Fatal("another Session received foreign working")
	default:
	}
	// Fill the a observer and publish once more: it is retired, never
	// allowed to stall the native EventHub or continue with a cursor gap.
	h.publishSessionFrame([]byte(`{"type":"assistant.text_delta","session_id":"session-a"}`))
	h.publishSessionFrame([]byte(`{"type":"assistant.text_delta","session_id":"session-a"}`))
	h.streamsMu.Lock()
	_, exists := h.streams[1]
	_, bExists := h.streams[2]
	h.streamsMu.Unlock()
	if exists || !bExists {
		t.Fatalf("failed to isolate slow viewer: a=%v b=%v", exists, bExists)
	}
	h.closeSessionStreams()
	h.closeSessionStreams()
}
