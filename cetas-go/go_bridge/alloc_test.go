package bridge

import (
	"bytes"
	"testing"
)

// The pump polls the native queue whenever it wakes, including long idle
// stretches with nothing queued. That path must not allocate: the pump owns
// one reusable scratch buffer and only the frames it actually returns carry
// their own bytes.
func TestIdlePollAllocatesNothing(t *testing.T) {
	h := transportUnderTest()
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	if allocs := testing.AllocsPerRun(200, func() {
		frame, err := h.Poll()
		if err != nil || frame != nil {
			t.Fatalf("idle poll returned %v, %v", frame, err)
		}
	}); allocs != 0 {
		t.Fatalf("idle Poll allocated %v objects per call, want 0", allocs)
	}
}

// A returned frame must own its bytes: the pump reuses its scratch buffer, so
// a second Poll may reuse the storage the first frame was copied out of.
func TestPolledFramesOwnTheirBytes(t *testing.T) {
	h := transportUnderTest()
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	first := testPayload(t, 4096)
	second := testPayload(t, 4096)
	for i := range second {
		second[i] ^= 0xff
	}
	if publishFrame(first) != 1 || publishFrame(second) != 1 {
		t.Fatal("publish failed")
	}
	a, err := h.Poll()
	if err != nil || !bytes.Equal(a, first) {
		t.Fatalf("first poll: %v", err)
	}
	b, err := h.Poll()
	if err != nil || !bytes.Equal(b, second) {
		t.Fatalf("second poll: %v", err)
	}
	if !bytes.Equal(a, first) {
		t.Fatal("second Poll overwrote the first frame's bytes")
	}
}
