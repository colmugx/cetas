//go:build !windows && cgo

package bridge

/*
#cgo darwin LDFLAGS: -L${SRCDIR}/lib -lcetas_moon
#cgo linux LDFLAGS: -L${SRCDIR}/lib -lcetas_moon -lpthread -lm -ldl
#include <stdint.h>
void cetas_host_boot(void);
int32_t cetas_host_infra_run(void);
int32_t cetas_host_send(int32_t);
int32_t cetas_host_poll_event(uint8_t*, int32_t, int32_t*);
int32_t cetas_host_event_drops(void);
void cetas_host_rejections(int32_t*, int32_t*, int32_t*, int32_t*);
void cetas_host_rejection_context(int32_t*);
int32_t cetas_host_submit_harness(const uint8_t*, int32_t);
int32_t cetas_bridge_publish(const uint8_t*, int32_t);
void cetas_heap_relief(void);
void cetas_heap_stats_file(const char*);
int32_t cetas_host_wait_event(void);
int32_t cetas_host_wake(void);
int32_t cetas_host_event_wake_stage(void);
int32_t cetas_host_event_wake_errno(void);
*/
import "C"
import "unsafe"

func callBoot()                 { C.cetas_host_boot() }
func callRun() int32            { return int32(C.cetas_host_infra_run()) }
func callSend(code int32) int32 { return int32(C.cetas_host_send(C.int32_t(code))) }
func callDrops() int32          { return int32(C.cetas_host_event_drops()) }
func callWait() int32           { return int32(C.cetas_host_wait_event()) }
func callWake() int32           { return int32(C.cetas_host_wake()) }
func callEventWakeStage() int32 { return int32(C.cetas_host_event_wake_stage()) }
func callEventWakeErrno() int32 { return int32(C.cetas_host_event_wake_errno()) }
func callRejections(a, b, c, d *int32) {
	C.cetas_host_rejections((*C.int32_t)(unsafe.Pointer(a)), (*C.int32_t)(unsafe.Pointer(b)),
		(*C.int32_t)(unsafe.Pointer(c)), (*C.int32_t)(unsafe.Pointer(d)))
}
func callRejectionContext(v *[5]int32) {
	C.cetas_host_rejection_context((*C.int32_t)(unsafe.Pointer(&v[0])))
}
func callPoll(buf []byte, flags *int32) int32 {
	return int32(C.cetas_host_poll_event((*C.uint8_t)(unsafe.Pointer(&buf[0])),
		C.int32_t(len(buf)), (*C.int32_t)(unsafe.Pointer(flags))))
}
func callPublish(buf []byte) int32 {
	if len(buf) == 0 {
		return int32(C.cetas_bridge_publish(nil, 0))
	}
	return int32(C.cetas_bridge_publish((*C.uint8_t)(unsafe.Pointer(&buf[0])), C.int32_t(len(buf))))
}
func callSubmit(buf []byte) int32 {
	return int32(C.cetas_host_submit_harness((*C.uint8_t)(unsafe.Pointer(&buf[0])), C.int32_t(len(buf))))
}

// HeapRelief collects MoonBit cycles and (only when explicitly compiled
// with CETAS_USE_MIMALLOC) releases free mimalloc pages. The system allocator
// needs no mimalloc symbols.
func HeapRelief() { C.cetas_heap_relief() }

// HeapStats writes the selected allocator's diagnostics. For a system
// allocator it records an explicit unsupported marker instead of pretending
// mimalloc statistics exist. The path is diagnostic-only.
func HeapStats(path string) {
	C.cetas_heap_stats_file(C.CString(path))
}
