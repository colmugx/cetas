// Standalone cross-process test client: this is a Go observer that never
// starts Cetas, composes an Agent or writes any Session journal.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"

	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

func main() {
	if len(os.Args) != 3 {
		fatal(fmt.Errorf("usage: observer <unix-socket> <session-id>"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", os.Args[1])
	if err != nil {
		fatal(err)
	}
	viewer, err := sb.ObserveConn(ctx, conn, os.Args[2], "independent-go-viewer")
	if err != nil {
		fatal(err)
	}
	defer viewer.Close()
	var snapshot struct {
		SessionID string `json:"session_id"`
		RuntimeEpoch string `json:"runtime_epoch"`
		Busy bool `json:"busy"`
	}
	if err := json.Unmarshal(viewer.Snapshot, &snapshot); err != nil ||
		snapshot.SessionID != os.Args[2] || !snapshot.Busy ||
		snapshot.RuntimeEpoch != viewer.Epoch {
		fatal(fmt.Errorf("invalid working Snapshot: %s: %v", viewer.Snapshot, err))
	}
	fmt.Println("READY")
	// A stalled listener cannot strand the cross-process CI test.
	kill := time.AfterFunc(10*time.Second, func() { _ = viewer.Close() })
	defer kill.Stop()
	raw, err := viewer.Next()
	if err != nil {
		fatal(err)
	}
	var frame struct {
		Type string `json:"type"`
		Delta string `json:"delta"`
		RuntimeEpoch string `json:"runtime_epoch"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil ||
		frame.Type != "assistant.text_delta" ||
		frame.Delta != "live from Bun subprocess owner" ||
		frame.RuntimeEpoch != viewer.Epoch {
		fatal(fmt.Errorf("wrong live Go viewer event: %s: %v", raw, err))
	}
}
func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
