package tui

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func writeTestImage(t *testing.T, cwd, name string, size int) {
	t.Helper()
	png := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, size)...)
	if err := os.MkdirAll(filepath.Dir(filepath.Join(cwd, name)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cwd, name), png, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestImageMentionResolutionAndCaps(t *testing.T) {
	cwd := t.TempDir()
	writeTestImage(t, cwd, "shot.png", 64)
	writeTestImage(t, cwd, "docs/big.jpeg", maxImageBytes+10)
	prompt := "look at @shot.png and @missing.png and @docs/big.jpeg please"
	attachments, warnings := resolveImageMentions(prompt, cwd)
	if len(attachments) != 1 || attachments[0].Label != "shot.png" || attachments[0].MediaType != "image/png" {
		t.Fatalf("resolution: %#v", attachments)
	}
	if attachments[0].Data == "" {
		t.Fatal("attachment carries no bytes")
	}
	joined := strings.Join(warnings, "\n")
	if !strings.Contains(joined, "missing.png") || !strings.Contains(joined, "5 MB") {
		t.Fatalf("warnings lost failures: %q", joined)
	}
}

func TestFindImageMentionsTrimsPunctuation(t *testing.T) {
	tokens := findImageMentions("see @quoted.png), and @plain.jpg.")
	if len(tokens) != 2 || tokens[0] != "quoted.png" || tokens[1] != "plain.jpg" {
		t.Fatalf("trim rules: %#v", tokens)
	}
	if len(tokens) == 0 {
		t.Fatal("no mentions found")
	}
	for _, token := range tokens {
		if strings.HasPrefix(token, "@") || strings.HasSuffix(token, ",") || strings.HasSuffix(token, ".") {
			t.Fatalf("trim rules: %q", token)
		}
	}
}

func TestSubmitAttachesMentionsAndStagedImages(t *testing.T) {
	cwd := t.TempDir()
	writeTestImage(t, cwd, "pic.png", 32)
	host := &imageRecordingHost{}
	m := newModel()
	m.host = host
	m.session = "s-1"
	m.surface.cwd = cwd
	m.textarea.SetValue("describe @pic.png")
	m.pendingImages = []imageAttachment{{MediaType: "image/png", Data: "c3RhZ2Vk", Label: "clipboard.png", Bytes: 6}}
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	state := next.(model)
	if len(state.pendingImages) != 0 {
		t.Fatal("submit must clear staged attachments")
	}
	for _, msg := range cmdMsgs(t, cmd) {
		_ = msg
	}
	sent := host.lastImages
	if len(sent) != 2 {
		t.Fatalf("turn_start images = %#v", sent)
	}
	if sent[0]["media_type"] != "image/png" || sent[1]["media_type"] != "image/png" {
		t.Fatalf("wire shape: %#v", sent)
	}
	if !strings.Contains(state.transcript[len(state.transcript)-1], "🖼") {
		t.Fatalf("echo row lacks attachment chips: %q", state.transcript)
	}
}

func TestEmptyPasteStagesClipboardImage(t *testing.T) {
	restore := readClipboardImage
	defer func() { readClipboardImage = restore }()
	readClipboardImage = func() (imageAttachment, bool) {
		return imageAttachment{MediaType: "image/png", Data: base64.StdEncoding.EncodeToString([]byte("\x89PNG fake")), Label: "clipboard.png", Bytes: 13}, true
	}
	m := newModel()
	m.host = &imageRecordingHost{}
	next, _ := m.Update(tea.PasteMsg{Content: ""})
	state := next.(model)
	if len(state.pendingImages) != 1 || state.pendingImages[0].Label != "clipboard.png" {
		t.Fatalf("empty paste did not stage the clipboard image: %#v", state.pendingImages)
	}
	if !strings.Contains(state.status, "clipboard.png") || !strings.Contains(state.status, "Enter sends") {
		t.Fatalf("staged summary missing: %q", state.status)
	}
	// Esc clears the staged set before arming rewind.
	m2 := state
	m2.lastProgramStatus = formatProgramStatus(m2.projectProgramStatus())
	after, _ := m2.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if len(after.(model).pendingImages) != 0 {
		t.Fatal("Esc must clear staged attachments")
	}
}

type imageRecordingHost struct {
	testHost
	lastImages []map[string]string
}

func (h *imageRecordingHost) Request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	if command == "turn_start" {
		if fields, ok := args.(map[string]any); ok {
			if images, ok := fields["images"].([]map[string]string); ok {
				h.lastImages = images
			} else if raw, ok := fields["images"]; ok {
				_ = raw
			}
		}
	}
	return h.testHost.Request(ctx, command, args)
}
