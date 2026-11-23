package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/colmugx/cetas/cetas-go/internal/tui/overlays"
)

func TestPickerPanelRendersReplacedRows(t *testing.T) {
	host := &sessionCatalogHost{total: 6, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)

	before, _, _, _, _ := m.overlayPanel()
	if !strings.Contains(strings.Join(before, "\n"), "session 00") {
		t.Fatal("picker did not render its initial rows")
	}

	// The replacement has the same row count, but the old content must disappear.
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
	reply := sessionReply(m, sessionPayload(t, "current", replacement, nil))
	next, _ := m.Update(reply)
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
