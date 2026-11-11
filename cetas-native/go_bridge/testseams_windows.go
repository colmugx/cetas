//go:build windows

package bridge

import (
 "runtime"
 "unsafe"
)
func drainWake() { for callInt(requireAPI().testReadWake) == 1 {} }
func commandChannelLive() bool { return callInt(requireAPI().testCommandOpen) == 1 }
func commandWakePending() bool { return callInt(requireAPI().testCommandWake) == 1 }
func takeCommand() int32 { return callInt(requireAPI().testNextCommand) }
func takeHarness() []byte {
 buf := make([]byte, HarnessLimit)
 n := callInt(requireAPI().testNextHarness, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
 runtime.KeepAlive(buf)
 if n <= 0 { return nil }
 return buf[:n]
}
