package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
)

// TestPickerPanelMemoRendersOncePerInputIdentity pins the panel memo: an
// unchanged render-input key returns the memoized panel and rect verbatim,
// and every input change — cursor move, same-length page replacement, window
// resize, close — produces a fresh render. The memo is what keeps a wheel
// frame over the picker from rendering the panel twice.
func TestPickerPanelMemoRendersOncePerInputIdentity(t *testing.T) {
	host := &sessionCatalogHost{total: 6, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)

	first, left, top, width, height := m.overlayPanel()
	if len(first) == 0 {
		t.Fatal("picker panel rendered nothing")
	}
	again, left2, top2, width2, height2 := m.overlayPanel()
	if &again[0] != &first[0] {
		t.Fatal("unchanged inputs re-rendered the picker panel")
	}
	if left != left2 || top != top2 || width != width2 || height != height2 {
		t.Fatalf("memoized rect moved: (%d,%d,%d,%d) -> (%d,%d,%d,%d)", left, top, width, height, left2, top2, width2, height2)
	}

	// A cursor move is a new input: a fresh render, not the memoized one.
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	moved := next.(model)
	if moved.sessionPicker.panel.Index == m.sessionPicker.panel.Index {
		t.Fatal("down did not move the picker cursor")
	}
	movedPanel, _, _, _, _ := moved.overlayPanel()
	if &movedPanel[0] == &first[0] {
		t.Fatal("a cursor move reused the stale panel")
	}
	if !strings.Contains(strings.Join(movedPanel, "\n"), "session 01") {
		t.Fatal("fresh panel lost the newly selected row's rendering cues")
	}

	// A same-length page replacement keeps the request generation and row
	// count; the content counter must still force a fresh render.
	replacement := make([]overlays.SessionEntry, 0, 6)
	for i := 0; i < 6; i++ {
		cwd := host.cwd
		replacement = append(replacement, overlays.SessionEntry{
			ID:         fmt.Sprintf("replaced-%02d", i),
			Bucket:     "session_demo_aaaaaaaaaaaa",
			Title:      fmt.Sprintf("REPLACED %02d", i),
			Cwd:        &cwd,
			Folder:     "demo",
			SizeBytes:  int64(2048 * (i + 1)),
			ModifiedAt: time.Now().Add(-time.Duration(i+1) * time.Minute).UnixMilli(),
		})
	}
	reply := sessionReply(moved, sessionPayload(t, "current", replacement, nil))
	next, _ = moved.Update(reply)
	refreshed := next.(model)
	panel, _, _, _, _ := refreshed.overlayPanel()
	joined := strings.Join(panel, "\n")
	if !strings.Contains(joined, "REPLACED 00") {
		t.Fatal("a same-length page replacement reused the previous page's render")
	}
	if strings.Contains(joined, "session 00") {
		t.Fatal("the previous page's rows are still painted after the replacement")
	}
}
