//go:build !cetas_pprof

package main

// startProfileEndpoint is a no-op in release builds: the diagnostics endpoint
// exists only in binaries built with -tags cetas_pprof, so the shipping binary
// carries no HTTP server or profile machinery.
func startProfileEndpoint() {}
