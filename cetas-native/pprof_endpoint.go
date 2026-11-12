//go:build cetas_pprof

package main

import (
	"net/http"
	_ "net/http/pprof"
	"os"

	"github.com/colmugx/cetas/cetas-native/go_bridge"
)

// startProfileEndpoint binds the standard pprof handlers when CETAS_PPROF names
// an address. It exists for profiling the live TUI under the PTY probes; the
// release binary never includes it.
func startProfileEndpoint() {
	addr := os.Getenv("CETAS_PPROF")
	if addr == "" {
		return
	}
	http.HandleFunc("/debug/relief", func(w http.ResponseWriter, _ *http.Request) {
		bridge.HeapRelief()
		_, _ = w.Write([]byte("relieved"))
	})
	go func() {
		_ = http.ListenAndServe(addr, nil)
	}()
}
