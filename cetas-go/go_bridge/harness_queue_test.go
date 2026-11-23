package bridge

import (
	"bytes"
	"errors"
	"testing"
)

func TestHarnessRequestFIFOOwnsBytesAcrossWraparound(t *testing.T) {
	if isolatedCommandChannel(t, "TestHarnessRequestFIFOOwnsBytesAcrossWraparound") {
		return
	}
	h := transportUnderTest()
	if err := h.Submit(make([]byte, HarnessLimit+1)); !errors.Is(err, ErrHarnessTooLarge) {
		t.Fatalf("oversized submit: %v", err)
	}
	const slots = 64
	// Reuse and overwrite the caller's buffer on every submit. The maximum
	// size first request also lets us probe without consuming the FIFO head.
	src := make([]byte, HarnessLimit)
	push := func(i, size int) {
		t.Helper()
		copy(src[:size], bytes.Repeat([]byte{byte(i + 1)}, size))
		if err := h.Submit(src[:size]); err != nil {
			t.Fatalf("submit %d: %v", i, err)
		}
		clear(src[:size])
	}
	pop := func(i, size int) {
		t.Helper()
		buf := make([]byte, size)
		if n := copyNextHarness(buf); n != size || !bytes.Equal(buf, bytes.Repeat([]byte{byte(i + 1)}, size)) {
			t.Fatalf("request %d: length %d or content changed (wanted %d bytes)", i, n, size)
		}
	}
	push(0, HarnessLimit)
	for i := 1; i < slots; i++ {
		push(i, i+1)
	}
	if err := h.Submit([]byte("full")); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("full submit: %v", err)
	}
	probe := []byte{0xfe}
	if n := copyNextHarness(probe); n != -HarnessLimit || probe[0] != 0xfe {
		t.Fatalf("undersized read must preserve head: length=%d buffer=%x", n, probe)
	}
	pop(0, HarnessLimit)
	for i := 1; i < slots/2; i++ {
		pop(i, i+1)
	}
	for i := slots; i < slots+slots/2; i++ {
		push(i, i+1)
	}
	for i := slots / 2; i < slots+slots/2; i++ {
		pop(i, i+1)
	}
	if n := copyNextHarness(probe); n != 0 {
		t.Fatalf("queue should be empty, got %d", n)
	}
}
