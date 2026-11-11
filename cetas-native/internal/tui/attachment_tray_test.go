package tui

import (
	"fmt"
	"time"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func trayModel(t *testing.T) *model {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	out := &m
	t.Cleanup(func() { out.Close() })
	return out
}

func TestAttachmentTrayRendersPlaceholdersAndFallback(t *testing.T) {
	m := trayModel(t)
	withKittySupport(t, func() {
		m.stageImageAttachments([]imageAttachment{{MediaType: "image/png", Data: pngFixture(t, 32, 16), Label: "shot.png", Bytes: 4096}})
		if len(m.kittyThumbs) != 1 {
			t.Fatalf("thumbnail not staged: %d", len(m.kittyThumbs))
		}
		lines := m.attachmentTrayLines(m.theme(), 80)
		if len(lines) != 5 { // header + 3 thumb rows + caption
			t.Fatalf("tray height %d, want 5", len(lines))
		}
		joined := strings.Join(lines, "\n")
		if !strings.Contains(joined, "1 image attached") || !strings.Contains(joined, "shot.png") {
			t.Fatalf("tray lost its labels: %q", joined)
		}
		if !strings.Contains(joined, "\x1b[38;5;") {
			t.Fatal("tray rows carry no placeholder cells")
		}
	})

	m2 := trayModel(t)
	withoutKittySupport(t, func() {
		m2.stageImageAttachments([]imageAttachment{{MediaType: "image/png", Data: pngFixture(t, 32, 16), Label: "shot.png", Bytes: 4096}})
		lines := m2.attachmentTrayLines(m2.theme(), 80)
		if len(lines) != 1 {
			t.Fatalf("fallback tray height %d, want 1", len(lines))
		}
		if !strings.Contains(lines[0], "shot.png") {
			t.Fatalf("fallback tray lost the label: %q", lines[0])
		}
	})
}

func TestClearStagedImagesDeletesThumbnailImages(t *testing.T) {
	m := trayModel(t)
	withKittySupport(t, func() {
		m.stageImageAttachments([]imageAttachment{{MediaType: "image/png", Data: pngFixture(t, 32, 16), Label: "shot.png", Bytes: 4096}})
		var thumb kittyImageLayout
		for _, layout := range m.kittyThumbs {
			thumb = layout
		}
		m.pendingKitty = nil
		m.clearStagedImages()
		if len(m.pendingImages) != 0 || len(m.kittyThumbs) != 0 {
			t.Fatal("clear left staged state behind")
		}
		if len(m.pendingKitty) != 1 || !strings.Contains(m.pendingKitty[0], fmt.Sprintf("a=d,i=%d", thumb.id)) {
			t.Fatalf("clear did not delete the thumbnail image: %v", m.pendingKitty)
		}
	})
}

// A paste whose whole body is an image file path becomes an attachment and
// never reaches the composer; anything else falls through as text.
func TestPasteImagePathStagesAttachment(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pasted.png")
	if err := os.WriteFile(path, []byte("\x89PNG\r\n\x1a\nIHDRgarbage"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := trayModel(t)
	m.surface.cwd = dir
	if token, ok := pasteImagePath(path, dir); !ok || token != "pasted.png" {
		t.Fatalf("pasteImagePath(%q) = %q, %v", path, token, ok)
	}
	if _, ok := pasteImagePath("read this "+path, dir); ok {
		t.Fatal("a paste with prose is not an image path paste")
	}
	if _, ok := pasteImagePath(filepath.Join(dir, "missing.png"), dir); ok {
		t.Fatal("a missing file is not attachable")
	}

	next, _ := m.update(tea.PasteMsg{Content: path})
	state := next.(model)
	if len(state.pendingImages) != 1 || state.pendingImages[0].Label != "pasted.png" {
		t.Fatalf("image path paste did not stage: %+v", state.pendingImages)
	}
	if state.textarea.Value() != "" {
		t.Fatalf("paste leaked the path into the composer: %q", state.textarea.Value())
	}

	next2, _ := m.update(tea.PasteMsg{Content: "see " + path + " for context"})
	if next2.(model).textarea.Value() == "" {
		t.Fatal("prose paste must still reach the composer")
	}
}

// The completion debounce owns a UI wake: after typing settles with no other
// animation running, the clock must still fire the staged request.
func TestCompletionDebounceOwnsAWake(t *testing.T) {
	m := trayModel(t)
	m.host = &imageRecordingHost{}
	m.session = "s-1"
	m.textarea.SetValue("read @doc")
	next, _ := m.update(tea.KeyPressMsg{Text: "s"})
	state := next.(model)
	due := state.nextUIWake(time.Now())
	if due.IsZero() || due.After(state.completionDueAt) {
		t.Fatalf("staged completion did not earn a wake: due=%v completion=%v", due, state.completionDueAt)
	}
}

func withKittySupport(t *testing.T, fn func()) {
	t.Helper()
	t.Setenv("GHOSTTY_RESOURCES_DIR", "/test-ghostty")
	t.Setenv("CETAS_NATIVE_DISABLE_IMAGE_DISPLAY", "")
	fn()
}

func withoutKittySupport(t *testing.T, fn func()) {
	t.Helper()
	t.Setenv("CETAS_NATIVE_DISABLE_IMAGE_DISPLAY", "1")
	fn()
}
