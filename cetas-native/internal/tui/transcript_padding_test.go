package tui

import (
	"encoding/json"
	"image/color"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// Transcript rows fill the terminal width, exactly like pi-tui's padded
// Markdown and user-surface lines. Full-width rows are what make a surface, a
// selection inversion and the auto scrollbar column cover the whole document
// instead of stopping at the last glyph of each message.
func TestTranscriptRowsPadToTerminalWidth(t *testing.T) {
	m := interactionModel(t, 40, 16, "short")
	m.surface.fg = color.RGBA{R: 240, G: 240, B: 240, A: 255}
	m.surface.bg = color.RGBA{R: 10, G: 10, B: 10, A: 255}
	m.appendUser("你好 task")
	m.appendAssistant("# heading\n\n**bold** paragraph that is long enough to wrap at forty columns")
	m.reflow()

	width := m.viewport.Width()
	if width != 40 {
		t.Fatalf("test needs a 40-column viewport: %d", width)
	}
	for index := 0; index < m.transcriptBlockCount(); index++ {
		rows := m.mountedTranscriptRows(index)
		if index > 0 && len(rows) < 2 {
			t.Fatalf("block %d lost its gap row: %d", index, len(rows))
		}
		for _, row := range rows {
			if got := ansi.StringWidth(row); got != width {
				t.Fatalf("block %d row is %d cells wide, want %d: %q", index, got, width, ansi.Strip(row))
			}
		}
	}
	// Markdown keeps pi-tui's one-cell left margin on every visible row.
	for _, row := range m.mountedTranscriptRows(2) {
		plain := ansi.Strip(row)
		if strings.TrimSpace(plain) != "" && !strings.HasPrefix(plain, " ") {
			t.Fatalf("Markdown row lost its left margin: %q", plain)
		}
	}
	// The user surface covers the padded row, not just the glyphs. The "> "
	// prompt prefix itself is the block renderer's contract
	// (internal/tui/transcript/block.go); this seam guarantees that whatever it
	// renders is padded to the full terminal width.
	if first := ansi.Strip(m.mountedTranscriptRows(1)[0]); !strings.HasPrefix(first, " ") {
		t.Fatalf("user row lost its left margin: %q", first)
	}
	if block := m.mountedTranscriptBlock(1); !strings.Contains(block, "\x1b[") {
		t.Fatal("user row has no surface styling")
	}
}

// A replayed prompt is the same block as a typed one. Replay delegates to the
// parent's appendUser, so the echo text, surface and padding cannot drift.
func TestReplayedUserPromptMatchesSubmittedUser(t *testing.T) {
	live := interactionModel(t, 40, 16, "previous answer")
	live.appendUser("你好 task")

	replayModel := interactionModel(t, 40, 16)
	payload := `{"items":[{"kind":"assistant","text":"previous answer"},{"kind":"user","text":"你好 task"}]}`
	next, _ := replayModel.Update(commandResult{name: "session_transcript", payload: json.RawMessage(payload)})
	replay := next.(model)

	if live.blocks[1].Kind != "user" || replay.blocks[1].Kind != "user" {
		t.Fatalf("prompt block kinds: live=%q replay=%q", live.blocks[1].Kind, replay.blocks[1].Kind)
	}
	if got, want := replay.mountedTranscriptBlock(1), live.mountedTranscriptBlock(1); got != want {
		t.Fatalf("replayed prompt differs from the typed one:\n got %q\nwant %q", ansi.Strip(got), ansi.Strip(want))
	}
	// The source row stays the copy/search contract for both paths.
	if live.transcript[1] != "> 你好 task" || replay.transcript[1] != "> 你好 task" {
		t.Fatalf("prompt source drifted: live=%q replay=%q", live.transcript[1], replay.transcript[1])
	}
}
