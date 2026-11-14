//go:build cetas_native_faults && !windows

package bridge

// Fault-injection builds only: the cgo preamble below is merged into the
// package build and defines CETAS_NATIVE_FAULT_INJECTION for host.c, which is
// the sole gate for the CETAS_NATIVE_TEST_FORCE_* env probes. Run with:
//
//	go test -tags cetas_native_faults ./go_bridge/...
//
// Release and ordinary test builds never define it, so no environment
// variable can degrade the notification channels in a shipped binary.

/*
#cgo CFLAGS: -DCETAS_NATIVE_FAULT_INJECTION
*/
import "C"
