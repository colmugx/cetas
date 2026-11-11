//go:build !windows

package bridge

// Observability seams for the transport's own tests. They read and mutate the
// same C queues the MoonBit owner loop does, so they live in a cgo file (a Go
// test file cannot reach C) and stay unexported: nothing outside the package
// can drive the native boundary through them.

/*
#include <stdint.h>
int32_t cetas_bridge_next_command(void);
int32_t cetas_bridge_next_harness(uint8_t*, int32_t);
int32_t cetas_bridge_read_wake(void);
int32_t cetas_bridge_read_command_wake(void);
int32_t cetas_bridge_command_channel_open(void);
int32_t cetas_bridge_command_fd(void);
*/
import "C"
import "unsafe"

// drainWake consumes every pending notification byte so a test can tell a
// fresh wakeup from one an earlier test left in the pipe.
func drainWake() {
	for int(C.cetas_bridge_read_wake()) == 1 {
	}
}

// commandChannelLive reports whether C still owns an available read end.
// It refuses access once the descriptor has transferred to the scheduler;
// probing the fd number after transfer would race its closure/reuse.
func commandChannelLive() bool { return int(C.cetas_bridge_command_channel_open()) == 1 }

// claimCommandChannel transfers its read end exactly like the MoonBit owner.
// Its caller must own and close the returned descriptor.
func claimCommandChannel() int { return int(C.cetas_bridge_command_fd()) }

// commandWakePending reports, and consumes, one pending notification on the
// command channel the MoonBit scheduler waits on.
func commandWakePending() bool { return int(C.cetas_bridge_read_command_wake()) == 1 }

// takeHarness removes the next queued harness request the way the MoonBit
// owner loop does, so tests can observe what Submit enqueued.
func takeHarness() []byte {
	buf := make([]byte, HarnessLimit)
	n := int(C.cetas_bridge_next_harness((*C.uint8_t)(unsafe.Pointer(&buf[0])), C.int32_t(len(buf))))
	if n <= 0 {
		return nil
	}
	return buf[:n]
}

// takeCommand removes the next queued host command exactly the way the
// MoonBit owner loop does, so tests can observe what Send enqueued.
func takeCommand() int32 { return int32(C.cetas_bridge_next_command()) }
