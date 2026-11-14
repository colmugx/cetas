package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Streaming reasoning renders pi-tui's live ThinkingComponent: a braille
// spinner with "thinking..." and only the last three lines that have arrived.
// The spinner is the shell clock's frame, so no animation is scheduled here.
func TestLiveThinkingPreviewShowsSpinnerAndLastThreeLines(t *testing.T) {
	m := newModel()
	// A tall terminal so the whole live preview fits the transcript window: the
	// assertions below are about the block's own presentation.
	m.width, m.height = 80, 40
	m.resize()
	m.applyEvent(event(`{"type":"turn.started"}`))
	m.applyEvent(event(fmt.Sprintf(`{"type":"assistant.reasoning_delta","delta":%q}`, "first\nsecond\nthird\nfourth")))
	m.reflow()
	if m.viewport.Height() < 7 {
		t.Fatalf("test needs a transcript window of at least 7 rows: %d", m.viewport.Height())
	}

	view := ansi.Strip(m.viewport.View())
	if !strings.Contains(view, "⠋ thinking...") {
		t.Fatalf("live preview has no spinner header: %q", view)
	}
	for _, want := range []string{"second", "third", "fourth"} {
		if !strings.Contains(view, want) {
			t.Fatalf("live preview lost %q: %q", want, view)
		}
	}
	if strings.Contains(view, "first") {
		t.Fatalf("live preview is not the trailing three lines: %q", view)
	}

	// One 80ms clock frame advances the braille spinner; it must not need a
	// Markdown render or a new timer chain of its own.
	next, _ := m.Update(clockTick(time.Now().Add(80 * time.Millisecond)))
	m = next.(model)
	advanced := ansi.Strip(m.viewport.View())
	if strings.Contains(advanced, "⠋ thinking...") || !strings.Contains(advanced, "⠙ thinking...") {
		t.Fatalf("spinner did not advance on the clock frame: %q", advanced)
	}
	if !strings.Contains(advanced, "fourth") {
		t.Fatalf("clock frame lost the reasoning tail: %q", advanced)
	}
}

// The thought block keeps its place above its answer for the live stream and
// for a replayed session, and the settled transcript holds exactly one thought
// header — the live preview is replaced, never duplicated.
func TestThinkingBlockKeepsItsPlaceAboveTheAnswer(t *testing.T) {
	reasoning := "one\ntwo\nthree\nREASONING_TAIL"

	live := newModel()
	live.width, live.height = 80, 24
	live.resize()
	live.applyEvent(event(`{"type":"turn.started"}`))
	live.applyEvent(event(fmt.Sprintf(`{"type":"assistant.reasoning_delta","delta":%q}`, reasoning)))
	live.applyEvent(event(`{"type":"assistant.text_delta","delta":"**answer**"}`))
	live.applyEvent(event(`{"type":"turn.completed"}`))
	live.reflow()

	replay := newModel()
	replay.width, replay.height = 80, 24
	replay.resize()
	payload := fmt.Sprintf(`{"items":[{"kind":"reasoning","text":%q},{"kind":"assistant","text":"**answer**"}]}`, reasoning)
	next, _ := replay.Update(commandResult{name: "session_transcript", payload: json.RawMessage(payload)})
	replay = next.(model)

	// Compare the transcript rows, not the whole screen: the shell's status and
	// header regions are the parent reducer's, and a "ready" versus connecting
	// status line legitimately changes the viewport height.
	liveRows, replayRows := strings.Join(live.mountedTranscriptRows(0), "\n"), strings.Join(replay.mountedTranscriptRows(0), "\n")
	if liveRows != replayRows {
		t.Fatalf("replayed think block differs from the live turn\nlive: %q\nreplay: %q", ansi.Strip(liveRows), ansi.Strip(replayRows))
	}
	block := ansi.Strip(liveRows)
	if strings.Contains(block, "thinking...") {
		t.Fatalf("settled transcript kept the live preview: %s", block)
	}
	if count := strings.Count(block, "thought"); count != 1 {
		t.Fatalf("settled transcript has %d thought headers: %s", count, block)
	}
	if thought, answer := strings.Index(block, "thought"), strings.Index(block, "answer"); thought < 0 || answer < 0 || thought > answer {
		t.Fatalf("thought block is not above its answer: %s", block)
	}
}

// A replayed message that only carries reasoning keeps its own block in source
// order instead of collapsing into an empty answer.
func TestReplayKeepsReasoningOnlyMessageBlock(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	payload := `{"items":[{"kind":"reasoning","text":"only a thought"},{"kind":"assistant","text":""},{"kind":"assistant","text":"later answer"}]}`
	next, _ := m.Update(commandResult{name: "session_transcript", payload: json.RawMessage(payload)})
	m = next.(model)
	if len(m.transcript) != 2 {
		t.Fatalf("reasoning-only message lost its block: %#v", m.transcript)
	}
	if m.blocks[0].Kind != "thinking" {
		t.Fatalf("reasoning-only message is not a thought block: %q", m.blocks[0].Kind)
	}
	if _, ok := m.blocks[1]; ok {
		t.Fatalf("answer was projected as a %q block instead of Markdown", m.blocks[1].Kind)
	}
	if view := ansi.Strip(m.viewport.View()); strings.Index(view, "only a thought") > strings.Index(view, "later answer") {
		t.Fatalf("reasoning block moved below the answer: %s", view)
	}
}
