//go:build windows

package bridge

import "testing"

func TestWindowsCommandWakeDoesNotBlockWithoutReader(t *testing.T) {
	if isolatedCommandChannel(t, "TestWindowsCommandWakeDoesNotBlockWithoutReader") {
		return
	}
	h := transportUnderTest()
	// The scheduler polls on Windows, so nobody consumes the notification.
	// Consume only the queue entries so it never fills, even across enough
	// commands to saturate a 64 KiB pipe.
	for i := 0; i < 1<<17; i++ {
		if err := h.Send(CommandPing); err != nil {
			t.Fatalf("send command %d: %v", i, err)
		}
		if got := takeCommand(); got != CommandPing {
			t.Fatalf("pop command %d: got %d", i, got)
		}
	}
	if !commandWakePending() || commandWakePending() {
		t.Fatal("unread Windows notifications did not coalesce to one wakeup")
	}
}
