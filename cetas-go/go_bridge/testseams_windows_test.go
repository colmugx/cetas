//go:build windows

package bridge

import (
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func bridgeTestProc(name string) *windows.Proc {
	proc, err := requireAPI().dll.FindProc(name)
	if err != nil {
		panic(err)
	}
	return proc
}

func drainWake() {
	proc := bridgeTestProc("cetas_bridge_read_wake")
	for callInt(proc) == 1 {
	}
}
func commandChannelLive() bool {
	return callInt(bridgeTestProc("cetas_bridge_command_channel_open")) == 1
}
func commandWakePending() bool { return callInt(bridgeTestProc("cetas_bridge_read_command_wake")) == 1 }
func takeCommand() int32       { return callInt(bridgeTestProc("cetas_bridge_next_command")) }
func takeHarness() []byte {
	buf := make([]byte, HarnessLimit)
	n := copyNextHarness(buf)
	if n <= 0 {
		return nil
	}
	return buf[:n]
}

func copyNextHarness(buf []byte) int {
	n, _, _ := syscall.SyscallN(bridgeTestProc("cetas_bridge_next_harness").Addr(), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	runtime.KeepAlive(buf)
	return int(int32(n))
}
