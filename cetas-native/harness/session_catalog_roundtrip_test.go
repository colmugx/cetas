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

type catalogRow struct {
	ID string `json:"id"`
}

type catalogPage struct {
	Scope string       `json:"scope"`
	Items []catalogRow `json:"items"`
	Next  *string      `json:"next"`
	Total int          `json:"total"`
	Error string       `json:"error"`
}

// The real console catalog, driven end-to-end through the harness: the
// continuation anchor from one page replays as the `after` selector of the
// next request without duplicating or skipping a row, and a malformed anchor
// is a caller error, never a silent page 0.
func checkSessionCatalogAnchorRoundTrip(t *testing.T, h *Host, home string) {
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
	bucket := filepath.Dir(journal)
	base := time.Now().Add(-time.Hour)
	ids := []string{}
	for i, age := range []time.Duration{50 * time.Minute, 40 * time.Minute, 30 * time.Minute, 20 * time.Minute, 10 * time.Minute} {
		id := "cetas-910000000000" + string(rune('0'+i))
		path := filepath.Join(bucket, id+".jsonl")
		fixture := "{\"posoco.title\":\"anchor round trip " + string(rune('0'+i)) + "\"}\n" +
			"{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"anchor row " + string(rune('0'+i)) + "\"}]}\n"
		if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
			t.Fatal(err)
		}
		defer os.Remove(path)
		stamp := base.Add(age)
		if err := os.Chtimes(path, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fetch := func(after string, limit int) catalogPage {
		t.Helper()
		payload, err := h.Request(ctx, "session_catalog", map[string]any{"scope": "current", "after": after, "limit": limit})
		if err != nil {
			t.Fatalf("session_catalog(after=%q) failed: %v", after, err)
		}
		var page catalogPage
		if err := json.Unmarshal(payload, &page); err != nil {
			t.Fatalf("session_catalog reply: %v", err)
		}
		if page.Error != "" {
			t.Fatalf("session_catalog(after=%q) errored: %s", after, page.Error)
		}
		return page
	}
	first := fetch("", 2)
	if len(first.Items) != 2 {
		t.Fatalf("first page returned %d rows, want the requested 2", len(first.Items))
	}
	if first.Next == nil || *first.Next == "" {
		t.Fatal("a truncated page did not return a continuation anchor")
	}
	second := fetch(*first.Next, 100)
	seen := map[string]bool{}
	for _, item := range append(append([]catalogRow{}, first.Items...), second.Items...) {
		if seen[item.ID] {
			t.Fatalf("anchor round trip duplicated row %s", item.ID)
		}
		seen[item.ID] = true
	}
	if len(seen) < len(ids) {
		t.Fatalf("anchor round trip skipped rows: saw %d of the %d fixtures (plus the scripted session)", len(seen), len(ids))
	}
	// Anchor order is mtime-descending: every first-page row predates every
	// second-page row's modification time.
	info := func(id string) time.Time {
		st, err := os.Stat(filepath.Join(bucket, id+".jsonl"))
		if err != nil {
			t.Fatal(err)
		}
		return st.ModTime()
	}
	for _, early := range first.Items {
		for _, late := range second.Items {
			if info(early.ID).Before(info(late.ID)) {
				t.Fatalf("page order broke mtime descent: %s (page 1) is older than %s (page 2)", early.ID, late.ID)
			}
		}
	}
	// A malformed anchor is refused, never read as page 0.
	payload, err := h.Request(ctx, "session_catalog", map[string]any{"scope": "current", "after": "not-an-anchor", "limit": 2})
	if err == nil {
		var page catalogPage
		_ = json.Unmarshal(payload, &page)
		t.Fatalf("malformed anchor was accepted: %d rows (error=%q)", len(page.Items), page.Error)
	}
	if !strings.Contains(err.Error(), "cursor") && !strings.Contains(err.Error(), "anchor") {
		t.Fatalf("malformed anchor error does not name the selector: %v", err)
	}
}
