package tui

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// pngFixture builds a minimal PNG header with the given IHDR dimensions.
func pngFixture(t *testing.T, width, height uint32) string {
	t.Helper()
	png := []byte("\x89PNG\r\n\x1a\n")
	png = append(png, 0, 0, 0, 13)
	png = append(png, "IHDR"...)
	png = append(png,
		byte(width>>24), byte(width>>16), byte(width>>8), byte(width),
		byte(height>>24), byte(height>>16), byte(height>>8), byte(height),
		8, 6, 0, 0, 0)
	png = append(png, make([]byte, 64)...)
	return base64.StdEncoding.EncodeToString(png)
}

func TestPNGDimensions(t *testing.T) {
	w, h, ok := pngDimensions(pngFixture(t, 1920, 1080))
	if !ok || w != 1920 || h != 1080 {
		t.Fatalf("dimensions: %d %d %v", w, h, ok)
	}
	if _, _, ok := pngDimensions(base64.StdEncoding.EncodeToString([]byte("not a png at all"))); ok {
		t.Fatal("non-PNG accepted")
	}
}

func TestKittyPlaceholderLinesMatchSpecShape(t *testing.T) {
	got := kittyPlaceholderLines(42, 2, 2)
	want := "\x1b[38;5;42m\U0010EEEE\u0305\U0010EEEE\x1b[39m\n" +
		"\x1b[38;5;42m\U0010EEEE\u030d\U0010EEEE\x1b[39m"
	if got != want {
		t.Fatalf("placeholder bytes:\n got %q\nwant %q", got, want)
	}
	// Two-digit rows use decimal digit diacritics, most significant first.
	lines := strings.Split(kittyPlaceholderLines(7, 1, 12), "\n")
	if !strings.Contains(lines[10], "\u0305\u030d") { // row 10 = digits '1','0'
		t.Fatalf("row 10 diacritics missing: %q", lines[10])
	}
}

func TestKittyTransmitChunking(t *testing.T) {
	small := kittyTransmit(3, "QUJD")
	if !strings.HasPrefix(small, "\x1b_Ga=t,q=2,i=3,f=100,m=0;QUJD\x1b\\") {
		t.Fatalf("single-chunk transmit: %q", small)
	}
	payload := strings.Repeat("A", 4096*2+5)
	big := kittyTransmit(4, payload)
	if !strings.Contains(big, "m=1;") {
		t.Fatal("first chunk must set m=1")
	}
	if strings.Count(big, "\x1b_G") != 3 {
		t.Fatalf("expected 3 chunks, got %d", strings.Count(big, "\x1b_G"))
	}
	if !strings.HasSuffix(big, "m=0;"+payload[8192:]+"\x1b\\") {
		t.Fatal("last chunk must close the run")
	}
}

func TestStageKittyImageRegistersAndDedupes(t *testing.T) {
	t.Setenv("CETAS_NATIVE_DISABLE_IMAGE_DISPLAY", "")
	t.Setenv("TERM", "xterm-ghostty")
	m := newModel()
	attachment := imageAttachment{MediaType: "image/png", Data: pngFixture(t, 800, 600), Label: "shot.png", Bytes: 100}
	first, ok := m.stageKittyImage(attachment, 100)
	if !ok || first.id != 1 {
		t.Fatalf("first stage: %#v ok=%v", first, ok)
	}
	if first.cols <= 0 || first.rows <= 0 || !strings.Contains(first.transmits, "a=t,q=2,i=1") {
		t.Fatalf("layout: %#v", first)
	}
	again, ok := m.stageKittyImage(attachment, 100)
	if !ok || again.id != first.id {
		t.Fatal("identical payload must reuse the id")
	}
	// Non-PNG or broken payloads never register.
	if _, ok := m.stageKittyImage(imageAttachment{MediaType: "image/jpeg", Data: "x"}, 100); ok {
		t.Fatal("jpeg must fall back")
	}
	if _, ok := m.stageKittyImage(imageAttachment{MediaType: "image/png", Data: "!!!"}, 100); ok {
		t.Fatal("broken png must fall back")
	}
}

func TestSubmitEmitsImageBlockAndTransmit(t *testing.T) {
	t.Setenv("TERM", "xterm-ghostty")
	cwd := t.TempDir()
	host := &imageRecordingHost{}
	m := newModel()
	m.host = host
	m.session = "s-1"
	m.surface.cwd = cwd
	data := pngFixture(t, 800, 600)
	if err := writeRawFile(cwd, "pic.png", data); err != nil {
		t.Fatal(err)
	}
	m.textarea.SetValue("see @pic.png")
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	state := next.(model)
	blocks := 0
	for _, b := range state.blocks {
		if b.Kind == "image" && b.ImageID > 0 {
			blocks++
		}
	}
	if blocks != 1 {
		t.Fatalf("no inline image block: %#v", state.blocks)
	}
	// The pipeline flushes the staged transmit into the returned command
	// (state.pendingKitty is consumed), so the sequence must ride tea.Raw.
	sawRaw := false
	for _, msg := range cmdMsgs(t, cmd) {
		if raw, ok := msg.(tea.RawMsg); ok {
			s, _ := raw.Msg.(string)
			if strings.Contains(s, "\x1b_Ga=t,q=2,i=1") && strings.Contains(s, "a=p,U=1,i=1") {
				sawRaw = true
			}
		}
	}
	if !sawRaw {
		t.Fatal("transmit sequence never reached the terminal")
	}
	// The rendered block carries placeholder rows.
	for index, b := range state.blocks {
		if b.Kind == "image" && b.ImageID > 0 {
			if rendered, ok := state.renderBlock(index); !ok || !strings.Contains(rendered, "\U0010EEEE") {
				t.Fatalf("image block did not render placeholders: %q", rendered)
			}
		}
	}
}

func writeRawFile(dir, name, base64Content string) error {
	data, err := base64.StdEncoding.DecodeString(base64Content)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, name), data, 0o644)
}
