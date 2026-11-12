//go:build windows

package bridge

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

// MSVC links host.c and the MoonBit runtime into the DLL; Go never links
// the MSVC static archive or requires cgo on Windows.
type nativeAPI struct {
	dll                                                        *windows.DLL
	boot, run, send, poll, drops, rejections, rejectionContext *windows.Proc
	submit, publish, wait, wake, wakeStage, wakeErrno          *windows.Proc
	testReadWake, testNextCommand, testNextHarness             *windows.Proc
	testCommandOpen, testCommandWake                           *windows.Proc
}

var (
	apiOnce     sync.Once
	apiInstance *nativeAPI
	apiError    error
)

func loadNativeAPI() (*nativeAPI, error) {
	// Go test binaries live in temporary directories, unlike packaged cetas.
	path := os.Getenv("CETAS_NATIVE_DLL")
	if path == "" {
		executable, err := os.Executable()
		if err != nil {
			return nil, err
		}
		if resolved, err := filepath.EvalSymlinks(executable); err == nil {
			executable = resolved
		}
		path = filepath.Join(filepath.Dir(executable), "cetas_moon.dll")
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	dll, err := windows.LoadDLL(path)
	if err != nil {
		return nil, fmt.Errorf("load MoonBit DLL %q: %w", path, err)
	}
	api := &nativeAPI{dll: dll}
	bindings := []struct {
		name string
		dest **windows.Proc
	}{
		{"cetas_host_boot", &api.boot},
		{"cetas_host_infra_run", &api.run},
		{"cetas_host_send", &api.send},
		{"cetas_host_poll_event", &api.poll},
		{"cetas_host_event_drops", &api.drops},
		{"cetas_host_rejections", &api.rejections},
		{"cetas_host_rejection_context", &api.rejectionContext},
		{"cetas_host_submit_harness", &api.submit},
		{"cetas_bridge_publish", &api.publish},
		{"cetas_host_wait_event", &api.wait},
		{"cetas_host_wake", &api.wake},
		{"cetas_host_event_wake_stage", &api.wakeStage},
		{"cetas_host_event_wake_errno", &api.wakeErrno},
		{"cetas_bridge_read_wake", &api.testReadWake},
		{"cetas_bridge_next_command", &api.testNextCommand},
		{"cetas_bridge_next_harness", &api.testNextHarness},
		{"cetas_bridge_command_channel_open", &api.testCommandOpen},
		{"cetas_bridge_read_command_wake", &api.testCommandWake},
	}
	for _, binding := range bindings {
		p, err := dll.FindProc(binding.name)
		if err != nil {
			_ = dll.Release()
			return nil, fmt.Errorf("missing DLL export %s: %w", binding.name, err)
		}
		*binding.dest = p
	}
	return api, nil
}
func requireAPI() *nativeAPI {
	apiOnce.Do(func() { apiInstance, apiError = loadNativeAPI() })
	if apiError != nil {
		panic(fmt.Errorf("cetas bridge: %w", apiError))
	}
	return apiInstance
}
func callInt(proc *windows.Proc, args ...uintptr) int32 {
	result, _, _ := proc.Call(args...)
	return int32(result)
}
func callBoot()                 { callInt(requireAPI().boot) }
func callRun() int32            { return callInt(requireAPI().run) }
func callSend(code int32) int32 { return callInt(requireAPI().send, uintptr(uint32(code))) }
func callDrops() int32          { return callInt(requireAPI().drops) }
func callWait() int32           { return callInt(requireAPI().wait) }
func callWake() int32           { return callInt(requireAPI().wake) }
func callEventWakeStage() int32 { return callInt(requireAPI().wakeStage) }
func callEventWakeErrno() int32 { return callInt(requireAPI().wakeErrno) }
func addr(p *int32) uintptr     { return uintptr(unsafe.Pointer(p)) }
func callRejections(a, b, c, d *int32) {
	callInt(requireAPI().rejections, addr(a), addr(b), addr(c), addr(d))
	runtime.KeepAlive(a)
	runtime.KeepAlive(b)
	runtime.KeepAlive(c)
	runtime.KeepAlive(d)
}
func callRejectionContext(v *[5]int32) {
	callInt(requireAPI().rejectionContext, addr(&v[0]))
	runtime.KeepAlive(v)
}
func callPoll(buf []byte, flags *int32) int32 {
	n, _, _ := syscall.Syscall6(requireAPI().poll.Addr(), 3, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), addr(flags), 0, 0, 0)
	runtime.KeepAlive(buf)
	runtime.KeepAlive(flags)
	return int32(n)
}
func callPublish(buf []byte) int32 {
	if len(buf) == 0 {
		return callInt(requireAPI().publish, 0, 0)
	}
	n, _, _ := syscall.Syscall6(requireAPI().publish.Addr(), 2, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0, 0, 0)
	runtime.KeepAlive(buf)
	return int32(n)
}
func callSubmit(buf []byte) int32 {
	n, _, _ := syscall.Syscall6(requireAPI().submit.Addr(), 2, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0, 0, 0)
	runtime.KeepAlive(buf)
	return int32(n)
}
