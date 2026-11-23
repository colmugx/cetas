package harness

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPumpRoutesFrameHeaderWithoutChangingWireFrames(t *testing.T) {
	const delta = `{"type":"assistant.text_delta","session_id":"session-a","runtime_epoch":"epoch","cursor":1,"id":"call-id","delta":"hello"}`
	const execute = `{"type":"pi.guest.execute","session_id":"session-a","request_id":"r","tool_name":"echo","call_id":"c","arguments":{"text":"hello"}}`
	const noSession = `{"type":"assistant.text_delta","session_id":42,"delta":"unroutable"}`
	const badCursor = `{"type":"assistant.text_delta","session_id":"session-a","cursor":"bad","delta":"still delivered"}`
	const badID = `{"type":"harness.response","id":"not-numeric","result":null}`
	const response = `{"type":"harness.response","id":7,"result": {"ok": true},"session_id":false}`
	const stopped = `{"type":"infra.stopped"}`
	payloads := []string{delta, execute, noSession, badCursor, badID, response, stopped}
	transport := &fakeTransport{}
	for _, payload := range payloads {
		transport.payload = append(transport.payload, []byte(payload))
	}
	h := newHost(transport)
	observer := make(chan json.RawMessage, 4)
	h.streams[1] = sessionStream{sessionID: "session-a", frames: observer}
	worker := make(chan piGuestFrame, 4)
	h.pi.workers["session-a"] = worker
	answer := make(chan json.RawMessage, 1)
	h.pending[7] = answer
	h.pump()

	checkFrames := func(next func() string, want ...string) {
		t.Helper()
		for _, expected := range want {
			if got := next(); got != expected {
				t.Fatalf("raw frame = %q, want %q", got, expected)
			}
		}
	}
	checkFrames(func() string { return string((<-h.events).Raw) }, delta, execute, noSession, badCursor, stopped, "")
	checkFrames(func() string { return string(<-observer) }, delta, execute, badCursor, "")
	close(worker)
	checkFrames(func() string { return string((<-worker).frame) }, delta)
	if got := (<-worker).execution; got == nil || got.RequestID != "r" ||
		got.ToolName != "echo" || got.CallID != "c" || string(got.Arguments) != `{"text":"hello"}` {
		t.Fatalf("queued tool call changed: %+v", got)
	}
	checkFrames(func() string { return string((<-worker).frame) }, badCursor, "")
	select {
	case raw := <-answer:
		if string(raw) != `{"ok": true}` {
			t.Fatalf("correlated result changed: %s", raw)
		}
	default:
		t.Fatal("response did not reach its waiter")
	}
	if err := <-h.problems; err == nil || !strings.Contains(err.Error(), "Pi observer frame") {
		t.Fatalf("bad session ID did not produce a Pi diagnostic: %v", err)
	}
}

func TestParseFrameHeaderKeepsTagValidation(t *testing.T) {
	for _, raw := range []string{`{"type":`, `{"cursor":false,"TYPE":17}`, `[]`} {
		if _, err := parseFrameHeader([]byte(raw)); err == nil {
			t.Errorf("accepted invalid EventHub tag: %s", raw)
		}
	}
	header, err := parseFrameHeader([]byte(`{"TYPE":"assistant.text_delta","SESSION_ID":"s","runtime_epoch":"e","cursor":3}`))
	if err != nil || header.Type != "assistant.text_delta" || header.SessionID != "s" || header.RuntimeEpoch != "e" || header.Cursor != 3 {
		t.Fatalf("header = %+v (%v)", header, err)
	}
}
