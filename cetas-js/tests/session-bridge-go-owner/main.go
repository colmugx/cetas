// Independent Go Owner test fixture for the Bun Session viewer integration.
// This serves the same Posoco read-only Session protocol, without composing a
// second Agent, writing a Journal, or relying on Malphite.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"

	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: go-owner <unix-socket> <busy|idle>")
		os.Exit(2)
	}
	endpoint := os.Args[1]
	working := os.Args[2] == "busy"
	listener, err := net.Listen("unix", endpoint)
	if err != nil { fatal(err) }
	defer listener.Close()
	if err := os.Chmod(endpoint, 0600); err != nil { fatal(err) }
	events := make(chan json.RawMessage, 8)
	go func() {
		conn, err := listener.Accept()
		if err != nil { return }
		busy := "false"
		if working { busy = "true" }
		snapshot := json.RawMessage(fmt.Sprintf(
			`{"type":"session.snapshot","session_id":"go-owner-session","runtime_epoch":"go-epoch","cursor":0,"high_water_cursor":0,"busy":%s}`, busy,
		))
		_ = sb.ServeConn(context.Background(), conn,
			sb.Owner{InstanceID: "independent-go-owner", RuntimeEpoch: "go-epoch"},
			func(_ context.Context, id string) (sb.Subscription, error) {
				if id != "go-owner-session" { return sb.Subscription{}, fmt.Errorf("Session not owned") }
				return sb.Subscription{Snapshot: snapshot, Events: events}, nil
			})
	}()
	fmt.Println("GO_OWNER_READY")
	reader := bufio.NewScanner(os.Stdin)
	for reader.Scan() {
		if reader.Text() != "EMIT" { continue }
		if !working {
			events <- json.RawMessage(`{"type":"turn.accepted","session_id":"go-owner-session","runtime_epoch":"go-epoch","cursor":1,"cursor_advance":true}`)
		}
		cursor := 1
		if !working { cursor = 2 }
		events <- json.RawMessage(fmt.Sprintf(
			`{"type":"assistant.text_delta","session_id":"go-owner-session","runtime_epoch":"go-epoch","cursor":%d,"cursor_advance":true,"delta":"Go owner output to Bun"}`,
			cursor,
		))
	}
	close(events)
}
func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
