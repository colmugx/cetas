package tui

import (
	"errors"
	"fmt"
	"image/color"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestIdleUIStopsSchedulingFrames(t *testing.T) {
	m := newModel()
	// Seed the terminal status report: the assertion is about scheduling,
	// not about the first OSC 7501 frame.
	m.lastProgramStatus = formatProgramStatus(m.projectProgramStatus())
	next, cmd := m.Update(clockTick(time.Now()))
	if cmd != nil {
		t.Fatal("idle UI scheduled another periodic frame")
	}
	if next.(model).running {
		t.Fatal("idle frame changed runtime posture")
	}
}

func TestRuntimeErrorBecomesTranscriptNoticeNotEditorStatus(t *testing.T) {
	m := newModel()
	m.textarea.SetValue("keep my draft")
	next, _ := m.Update(commandResult{name: "status_refresh", err: errors.New("offline test failure")})
	m = next.(model)
	if !strings.Contains(strings.Join(m.transcript, "\n"), "offline test failure") {
		t.Fatal("error did not enter transcript")
	}
	if strings.Contains(strings.Join(m.regions().status, "\n"), "offline test failure") {
		t.Fatal("error is still drawn in editor's status region")
	}
	if m.textarea.Value() != "keep my draft" {
		t.Fatal("error corrupted editor draft")
	}
	n := len(m.transcript)
	next, _ = m.Update(clockTick(time.Now()))
	if len(next.(model).transcript) != n {
		t.Fatal("redraw appended the same error twice")
	}
}

func TestHostStopFinalizesStreamAndStopsIdleClock(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.running = true
	m.streaming = "**partial** answer"
	m.reflow()
	m.streaming += " before host exit"
	m.reflow()
	worker := m.document.markdown
	if worker == nil {
		t.Fatal("fixture did not start Markdown worker")
	}
	defer worker.stop()
	next, cmd := m.Update(eventBatchResult{closed: true})
	m = next.(model)
	if m.running || m.markdownRenderPending() {
		t.Fatal("closed host left an animation/Markdown clock running")
	}
	// The only command a closed host may leave is the terminal status clear.
	for _, msg := range cmdMsgs(t, cmd) {
		if raw, ok := msg.(tea.RawMsg); !ok || !strings.Contains(fmt.Sprint(raw.Msg), "state=clear") {
			t.Fatalf("closed host left work scheduled: %#v", msg)
		}
	}
	if !strings.Contains(strings.Join(m.transcript, "\n"), "before host exit") {
		t.Fatal("host stop lost the visible partial answer")
	}
	select {
	case <-worker.done:
	default:
		t.Fatal("host stop retained the Markdown worker")
	}
}

func TestNativeTransportDegradationIsVisibleInTranscript(t *testing.T) {
	m := newModel()
	m.textarea.SetValue("keep this draft")
	next, _ := m.Update(eventResult{ok: true, event: event(`{"type":"infra.error","detail":"command notification channel unavailable; falling back to 10 ms command polling","degraded":"command_poll_10ms"}`)})
	m = next.(model)
	if !strings.Contains(strings.Join(m.transcript, "\n"), "falling back to 10 ms command polling") {
		t.Fatal("transport degradation was silently discarded")
	}
	if m.textarea.Value() != "keep this draft" || strings.Contains(strings.Join(m.regions().status, "\n"), "10 ms") {
		t.Fatal("transport diagnostic rendered in the editor region")
	}
}

func TestSubmittedUserMessageUsesPaddedFullWidthSurface(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.session = "s1"
	m.surface.fg = color.RGBA{R: 240, G: 240, B: 240, A: 255}
	m.surface.bg = color.RGBA{R: 10, G: 10, B: 10, A: 255}
	m.width = 40
	m.height = 24
	m.textarea.SetValue("你好 task")
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if len(m.transcript) != 1 {
		t.Fatalf("user echo absent: %v", m.transcript)
	}
	rendered := m.mountedTranscriptBlock(0)
	if !strings.Contains(rendered, "\x1b[") {
		t.Fatal("user block has no background styling")
	}
	lines := strings.Split(rendered, "\n")
	// The panel is a framed box: blank bg row, padded content row, blank bg
	// row, every one exactly the transcript width.
	if len(lines) != 3 {
		t.Fatalf("user panel is not framed: %d lines", len(lines))
	}
	for i, line := range lines {
		if w := ansi.StringWidth(line); w != 40 {
			t.Fatalf("panel row %d is %d cells, want 40: %q", i, w, ansi.Strip(line))
		}
	}
	if body := ansi.Strip(lines[1]); !strings.HasPrefix(body, "  ") || !strings.Contains(body, "> 你好 task") {
		t.Fatalf("content row lost its prompt margins: %q", body)
	}
	if strings.TrimSpace(ansi.Strip(lines[0])) != "" || strings.TrimSpace(ansi.Strip(lines[2])) != "" {
		t.Fatal("panel frame rows are not blank")
	}
}
