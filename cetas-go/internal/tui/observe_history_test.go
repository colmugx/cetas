package tui

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// A minimal bridge owner over a pipe: it answers the observe handshake with
// an idle snapshot and then holds the connection open in silence.
func fakeBridgeOwner(t *testing.T, sessionID string) *sb.Observer {
	t.Helper()
	ownerPeer, viewerPeer := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() {
		defer ownerPeer.Close()
		reader := bufio.NewReader(ownerPeer)
		readLine := func() map[string]json.RawMessage {
			line, err := reader.ReadBytes('\n')
			if err != nil {
				return nil
			}
			var frame map[string]json.RawMessage
			_ = json.Unmarshal(line, &frame)
			return frame
		}
		write := func(frame map[string]any) {
			data, err := json.Marshal(frame)
			if err != nil {
				return
			}
			_, _ = ownerPeer.Write(append(data, '\n'))
		}
		readLine()
		write(map[string]any{"type": "welcome", "protocol": "posoco.session/1",
			"owner_instance_id": "owner", "runtime_epoch": "epoch-1",
			"capabilities": []string{"session.observe.v1"}})
		readLine()
		snapshot, _ := json.Marshal(map[string]any{"type": "session.snapshot",
			"session_id": sessionID, "runtime_epoch": "epoch-1",
			"cursor": 0, "high_water_cursor": 0, "busy": false})
		write(map[string]any{"type": "response", "request_id": "attach",
			"result": json.RawMessage(snapshot)})
		<-ctx.Done()
	}()
	dial, cancelDial := context.WithTimeout(ctx, 2*time.Second)
	defer cancelDial()
	observer, err := sb.ObserveConn(dial, viewerPeer, sessionID, "test-viewer")
	if err != nil {
		t.Fatalf("fake owner attach: %v", err)
	}
	return observer
}

func TestObservedSessionLoadsHistoryThroughReplayChannel(t *testing.T) {
	local := &pagedTestHost{session: "other", revision: "1:1:0", corpus: pagedUserCorpus(3)}
	replay := &pagedTestHost{session: "session-a", revision: "1:1:0", corpus: pagedUserCorpus(6)}
	m := newModel()
	defer m.Close()
	m.host = local
	m.switchInFlight = "session-a"
	observer := fakeBridgeOwner(t, "session-a")
	next, _ := m.Update(remoteAttachResult{sessionID: "session-a", observer: observer, replay: replay})
	m = next.(model)
	if m.session != "session-a" {
		t.Fatalf("attach did not adopt the session: %q", m.session)
	}
	if m.status != "observing Session (read-only)" {
		t.Fatalf("observer status: %q", m.status)
	}
	// The attach already kicked one replay start; this one supersedes it by
	// generation, so its pages are the ones that land.
	cmd := m.startPagedReplay()
	applied := 0
	for cmd != nil {
		results := pagedResults(cmd)
		if len(results) == 0 {
			break
		}
		var follow tea.Cmd
		for _, result := range results {
			nextCmd, _ := m.applyPagedReply(result)
			if nextCmd != nil {
				follow = nextCmd
			}
			applied++
		}
		cmd = follow
	}
	if applied == 0 {
		t.Fatal("observer history never loaded through the replay channel")
	}
	if len(replay.requests) == 0 {
		t.Fatal("the replay channel saw no transcript requests")
	}
	if len(local.requests) != 0 {
		t.Fatalf("the local harness received %d transcript requests", len(local.requests))
	}
	if m.transcriptBlockCount() == 0 {
		t.Fatal("transcript is empty after the paged replay landed")
	}
}

func TestObserverDisconnectClosesReplayChannel(t *testing.T) {
	replay := &pagedTestHost{session: "session-a", revision: "1:1:0", corpus: pagedUserCorpus(2)}
	m := newModel()
	defer m.Close()
	m.host = &pagedTestHost{session: "other", revision: "1:1:0", corpus: pagedUserCorpus(1)}
	m.switchInFlight = "session-a"
	observer := fakeBridgeOwner(t, "session-a")
	next, _ := m.Update(remoteAttachResult{sessionID: "session-a", observer: observer, replay: replay})
	m = next.(model)
	if m.remoteReplay == nil {
		t.Fatal("attach did not store the replay channel")
	}
	m.closeRemoteObserver()
	if m.remoteObserver != nil || m.remoteReplay != nil {
		t.Fatal("observer channels outlived the disconnect")
	}
}
