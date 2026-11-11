package harness

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Uses the already-started runtime: this integration package deliberately boots
// exactly one MoonBit owner per process. A cold index must yield to commands,
// not merely move its blocking wait to the Go caller's goroutine.
func checkReplayDoesNotMonopolizeDispatcher(t *testing.T, h *Host, home string) {
	t.Helper()
	var journal string
	if err := filepath.Walk(home, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".jsonl") && journal == "" {
			journal = path
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if journal == "" {
		t.Fatal("the scripted turn did not persist a journal")
	}
	const id = "cetas-9000000000000"
	path := filepath.Join(filepath.Dir(journal), id+".jsonl")
	defer os.Remove(path)
	writeColdReplayFixture(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := h.Request(ctx, "transcript_index", map[string]any{"session_id": id})
		done <- err
	}()
	time.Sleep(20 * time.Millisecond)
	select {
	case err := <-done:
		t.Fatalf("cold-index fixture ended before the concurrency check: %v", err)
	default:
	}
	healthCtx, stopHealth := context.WithTimeout(context.Background(), time.Second)
	defer stopHealth()
	if _, err := h.Request(healthCtx, "health", map[string]any{}); err != nil {
		t.Fatalf("cold replay index monopolized the command dispatcher: %v", err)
	}
	select {
	case err := <-done:
		t.Fatalf("health was only serviced after the cold index finished: %v", err)
	default:
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("cold replay did not finish: %v", err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	checkReplayClosesReadDescriptors(t, h, path, id)
	// Stop while another cold pass is pending, not only after it completed.
	writeColdReplayFixture(t, path)
	go func() {
		_, err := h.Request(ctx, "transcript_index", map[string]any{"session_id": id})
		done <- err
	}()
	time.Sleep(20 * time.Millisecond)
	select {
	case err := <-done:
		t.Fatalf("cold-index fixture ended before cancellation: %v", err)
	default:
	}
	if err := h.Close(ctx); err != nil {
		t.Fatalf("shutdown while indexing: %v", err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("shutdown let the retired cold index complete instead of cancelling it")
		}
	case <-ctx.Done():
		t.Fatal("shutdown left a replay caller waiting: ", ctx.Err())
	}
}

func writeColdReplayFixture(t *testing.T, path string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString("{}\n"); err != nil {
		t.Fatal(err)
	}
	line := `{"role":"system","content":[{"type":"text","text":"` + strings.Repeat("x", 65536) + `"}]}` + "\n"
	for i := 0; i < 2048; i++ {
		if _, err := file.WriteString(line); err != nil {
			t.Fatal(err)
		}
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

// A resume must not inherit the departed session's queued reads: the switch
// request sweeps them from the replay FIFO with a named error, while the job
// the worker already holds still runs to completion.
func checkSwitchSupersedesQueuedReplay(t *testing.T, h *Host, home string) {
	t.Helper()
	var journal string
	if err := filepath.Walk(home, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".jsonl") && journal == "" {
			journal = path
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if journal == "" {
		t.Fatal("the scripted turn did not persist a journal")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	payload, err := h.Request(ctx, "sessions", map[string]any{})
	if err != nil {
		t.Fatalf("sessions request failed: %v", err)
	}
	var listing struct {
		Active   string `json:"active"`
		Sessions []struct {
			ID     string `json:"id"`
			Active bool   `json:"active"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(payload, &listing); err != nil {
		t.Fatal(err)
	}
	active := listing.Active
	for _, entry := range listing.Sessions {
		if entry.Active && active == "" {
			active = entry.ID
			break
		}
	}
	if active == "" {
		t.Fatal("no active session in the sessions listing")
	}
	const gone = "cetas-9000000000001"
	path := filepath.Join(filepath.Dir(journal), gone+".jsonl")
	defer os.Remove(path)
	writeColdReplayFixture(t, path)
	// The worker holds the cold index for a while; the page reads pile up
	// behind it in the FIFO.
	indexDone := make(chan error, 1)
	go func() {
		_, err := h.Request(ctx, "transcript_index", map[string]any{"session_id": gone})
		indexDone <- err
	}()
	time.Sleep(20 * time.Millisecond)
	pageDone := make(chan error, 3)
	for i := 0; i < 3; i++ {
		go func() {
			_, err := h.Request(ctx, "transcript_page", map[string]any{"session_id": gone, "first": 0, "limit": 5})
			pageDone <- err
		}()
	}
	time.Sleep(20 * time.Millisecond)
	if _, err := h.Request(ctx, "switch_session", map[string]any{"id": active}); err != nil {
		t.Fatalf("switch request failed: %v", err)
	}
	for i := 0; i < 3; i++ {
		err := <-pageDone
		if err == nil || !strings.Contains(err.Error(), "superseded by session switch") {
			t.Fatalf("queued page read survived the switch: %v", err)
		}
	}
	select {
	case err := <-indexDone:
		if err != nil {
			t.Fatalf("worker-held index failed: %v", err)
		}
		t.Fatal("cold index finished before the switch; the fixture lost the race")
	default:
	}
	select {
	case err := <-indexDone:
		if err != nil {
			t.Fatalf("worker-held index was disturbed by the switch: %v", err)
		}
	case <-time.After(25 * time.Second):
		t.Fatal("worker-held index never completed")
	}
}

// The MoonBit async scope owns I/O handles until explicitly closed. Repeating
// page/source/list reads in a long-lived host must not accumulate one FD per
// request and only release them on process shutdown.
func checkReplayClosesReadDescriptors(t *testing.T, h *Host, path, id string) {
	t.Helper()
	fixture := `{"posoco.title":"descriptor fixture"}` + "\n" +
		`{"role":"user","content":[{"type":"text","text":"descriptor source"}]}` + "\n"
	if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	payload, err := h.Request(ctx, "transcript_index", map[string]any{"session_id": id})
	if err != nil {
		t.Fatal(err)
	}
	var index struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(payload, &index); err != nil || index.Revision == "" {
		t.Fatalf("invalid descriptor fixture index: %s (%v)", payload, err)
	}
	read := func() {
		for _, command := range []string{"transcript_page", "transcript_source", "sessions", "session_catalog"} {
			payload, err := h.Request(ctx, command, map[string]any{
				"session_id": id, "revision": index.Revision,
				"first": 0, "limit": 1, "index": 0, "length": 4,
			})
			if err != nil {
				t.Fatalf("descriptor fixture %s: %v", command, err)
			}
			if command == "session_catalog" {
				var catalog struct {
					Error string `json:"error"`
					Items []struct {
						ID   string `json:"id"`
						Size int64  `json:"sizeBytes"`
					} `json:"items"`
				}
				if err := json.Unmarshal(payload, &catalog); err != nil || catalog.Error != "" {
					t.Fatalf("native catalog route: %s (%v)", payload, err)
				}
				found := false
				for _, row := range catalog.Items {
					if row.ID == id && row.Size == int64(len(fixture)) {
						found = true
					}
				}
				if !found {
					t.Fatalf("catalog omitted fixture size metadata: %s", payload)
				}
			}
		}
	}
	read() // Account for lazily initialized async file workers before measuring.
	before := countOpenDescriptors(t)
	for i := 0; i < 20; i++ {
		read()
	}
	if after := countOpenDescriptors(t); after > before+4 {
		t.Fatalf("replay/list reads retained file descriptors: %d → %d", before, after)
	}
}
