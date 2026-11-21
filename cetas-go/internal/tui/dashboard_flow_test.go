package tui

import (
	"encoding/json"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
	"strings"
	"testing"
	"time"
)

func TestBlockingQuestionQueueUpdatesDashboardAwaitingCount(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	for _, raw := range []string{
		`{"type":"ui.request","request_id":"ask-1","kind":"confirm","prompt":"Continue?"}`,
		`{"type":"ui.request","request_id":"ask-2","kind":"confirm","prompt":"Allow?"}`,
	} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); !strings.Contains(screen, "2 awaiting reply") {
		t.Fatalf("blocking requests absent from dashboard: %q", screen)
	}
	for i, raw := range []string{`{"type":"ui.dismiss","request_id":"ask-1"}`, `{"type":"ui.dismiss","request_id":"ask-2"}`} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
		screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
		if i == 0 && !strings.Contains(screen, "1 awaiting reply") || i == 1 && strings.Contains(screen, "awaiting reply") {
			t.Fatalf("dismissed blocking requests kept stale counts: %q", screen)
		}
	}
}

func TestTallAskDoesNotDiscardStatusbarDetails(t *testing.T) {
	m := newModel()
	m.width, m.height = 80, 24
	m.applyEvent(event(`{"type":"turn.started"}`))
	m.applyEvent(event(`{"type":"ui.render","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"model","value":"provider/model:high"},{"key":"permission","value":"yolo"},{"key":"5h","value":"42%"}]}}}`))
	raw, err := json.Marshal(map[string]any{"type": "ui.request", "request_id": "long-ask", "kind": "select", "prompt": "Allow operation?\n" + strings.Repeat("A paragraph describing the operation.\n\n", 30), "options": []string{"Allow", "Deny"}})
	if err != nil {
		t.Fatal(err)
	}
	next, _ := m.Update(eventBatchResult{events: []wire.Event{event(string(raw))}})
	m = next.(model)
	screen := ansi.Strip(m.View().Content)
	if !strings.Contains(screen, "yolo") || !strings.Contains(screen, "5h 42%") {
		t.Fatalf("ask consumed the statusbar detail row: %q", screen)
	}
	if m.regions().editorY >= 24 || len(strings.Split(screen, "\n")) > 24 {
		t.Fatal("protecting statusbar pushed the editor outside the terminal")
	}
}

func TestStatusbarEntriesKeepRuntimeProviderIdentity(t *testing.T) {
	m := newModel()
	m.width = 108
	m.height = 36
	for _, raw := range []string{`{"type":"session.snapshot","model":"provider/model","effort":"high","permission":"yolo"}`, `{"type":"ui.render","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"model","value":"model:high"},{"key":"permission","value":"yolo"}]}}}`} {
		next, _ := m.Update(eventBatchResult{events: []wire.Event{event(raw)}})
		m = next.(model)
	}
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "provider/model:high") {
		t.Fatalf("status update erased actual selected provider: %q", screen)
	}
}
func TestQuestionAndChildEventsAppearInRenderedDashboard(t *testing.T) {
	m := newModel()
	m.width = 108
	m.height = 36
	events := []wire.Event{event(`{"type":"question.asked","question_id":"question-1","short_id":"@q1","question":"Continue?","kind":"confirm"}`), event(`{"type":"subagent.event","child_session":"child-1","parent_call":"call-1","kind":"explore","ev":{"type":"turn.started"}}`)}
	next, _ := m.Update(eventBatchResult{events: events})
	m = next.(model)
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "1 agent") || !strings.Contains(screen, "? 1 to answer") {
		t.Fatalf("received activity not presented in dashboard: %q", screen)
	}
	next, _ = m.Update(tea.WindowSizeMsg{Width: 40, Height: 24})
	m = next.(model)
	for _, line := range m.regions().dashboard {
		if ansi.StringWidth(line) > 40 {
			t.Fatalf("narrow dashboard overflow: %q", line)
		}
	}
}

// TestStatusbarLocalizesUTCTimestampEntries pins the one host-side status
// localization: MoonBit publishers emit timezone-free ISO-8601 UTC reset
// times and the TUI renders them on the user's wall clock, mirroring
// cetas-js formatStatusValue. Built from a local wall time so the assertion
// holds in every timezone.
func TestStatusbarLocalizesUTCTimestampEntries(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	utcReset := time.Date(2026, 1, 2, 3, 4, 5, 0, time.Local).UTC().Format("2006-01-02T15:04:05Z")
	m.applyEvent(event(`{"type":"ui.render","session_id":"s-1","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"Reset","value":"` + utcReset + `"}]}}}`))
	screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n"))
	if !strings.Contains(screen, "Reset 2026-01-02 03:04:05") || strings.Contains(screen, utcReset) {
		t.Fatalf("statusbar reset time not localized: %q", screen)
	}
}

func TestFormatStatusValue(t *testing.T) {
	local := time.Date(2026, 1, 2, 3, 4, 5, 0, time.Local)
	utcReset := local.UTC().Format("2006-01-02T15:04:05Z")
	if got := formatStatusValue(utcReset); got != "2026-01-02 03:04:05" {
		t.Fatalf("UTC reset time not converted to local wall clock: %q", got)
	}
	// Every non-timestamp value passes through untouched.
	for _, value := range []string{"12:00", "deepseek-v4-pro", "s1", "5h 92%"} {
		if got := formatStatusValue(value); got != value {
			t.Fatalf("non-timestamp value changed: %q -> %q", value, got)
		}
	}
	// A shape match that is not a real date is passed through, not zeroed.
	if got := formatStatusValue("2026-13-45T99:99:99Z"); got != "2026-13-45T99:99:99Z" {
		t.Fatalf("invalid date not passed through: %q", got)
	}
}

func TestSessionSwitchedDropsStatusbarAndSiblingPresentation(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	m.host = &testHost{}
	m.session = "s-1"
	for _, raw := range []string{
		`{"type":"ui.render","session_id":"s-1","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"Reset","value":"2026-11-21T14:54:51Z"}]}}}`,
		`{"type":"ui.render","session_id":"s-1","render":{"slot":"widget","key":"w","body":{"type":"text","text":"old widget"}}}`,
		`{"type":"ui.render","session_id":"s-1","render":{"slot":"status","key":"other","body":{"type":"text","text":"old status"}}}`,
		`{"type":"ui.render","session_id":"s-1","render":{"slot":"notice","key":"n","body":{"type":"text","text":"old notice"}}}`,
	} {
		m.applyEvent(event(raw))
	}
	if len(m.surface.entries) != 1 || len(m.surface.widgets) != 1 || len(m.surface.statuses) != 1 || len(m.surface.notices) != 1 {
		t.Fatal("pre-switch presentation did not mount")
	}
	m.applyEvent(event(`{"type":"session.switched","session_id":"s-2"}`))
	if m.session != "s-2" {
		t.Fatalf("switched event did not adopt the target session: %q", m.session)
	}
	// All presentation maps are session-owned: statusbar entries and expires,
	// widgets, statuses and notice blocks (with their transcript indices) are
	// reset with the departed session; only host chrome survives.
	if len(m.surface.entries) != 0 || !m.surface.entriesExpires.IsZero() ||
		len(m.surface.widgets) != 0 || len(m.surface.statuses) != 0 ||
		len(m.surface.notices) != 0 || len(m.surface.noticeExpires) != 0 {
		t.Fatalf("presentation crossed the session boundary: %#v", m.surface)
	}
	if screen := ansi.Strip(m.View().Content); strings.Contains(screen, "Reset") || strings.Contains(screen, "old widget") {
		t.Fatalf("departed session's segments still rendered: %q", screen)
	}
}

func TestStatusbarUnregisterClearsOwnSessionBar(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	// Traced end to end: the console uiport stamps every ui.render with the
	// owning session's id (HubUiPort.render -> EventHub::emit -> next_frame),
	// so the empty-entries frame an unregistered bar pushes passes the
	// foreign-session filter and clears the line. A rate-limit Reset segment
	// legitimately persists while recovery is pending — the bar clears only
	// when the registry truly empties. The value is built from a local wall
	// time so the on-screen expectation holds in every timezone.
	localReset := "2026-11-21 14:54:51"
	utcReset := time.Date(2026, 11, 21, 14, 54, 51, 0, time.Local).UTC().Format("2006-01-02T15:04:05Z")
	m.applyEvent(event(`{"type":"ui.render","session_id":"s-1","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[{"key":"Reset","value":"` + utcReset + `"}]}}}`))
	if len(m.surface.entries) != 1 {
		t.Fatalf("registered segment lost: %#v", m.surface.entries)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); !strings.Contains(screen, "Reset "+localReset) {
		t.Fatalf("registered segment not rendered: %q", screen)
	}
	m.applyEvent(event(`{"type":"ui.render","session_id":"s-1","render":{"slot":"status","key":"statusbar","body":{"type":"entries","entries":[]}}}`))
	if len(m.surface.entries) != 0 {
		t.Fatalf("unregistered bar did not clear: %#v", m.surface.entries)
	}
	if screen := ansi.Strip(strings.Join(m.regions().dashboard, "\n")); strings.Contains(screen, "Reset "+localReset) {
		t.Fatalf("cleared bar still rendered: %q", screen)
	}
}

func TestCompactFinishedLeavesTranscriptTrace(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	m.applyEvent(event(`{"type":"compact.finished","session_id":"s-1","mode":"auto","messages_after":3}`))
	if m.status != "ready" {
		t.Fatalf("compaction did not settle the status line: %q", m.status)
	}
	if len(m.transcript) != 1 || !strings.Contains(m.transcript[0], "context compacted (auto, 3 messages)") {
		t.Fatalf("compaction left no transcript trace: %#v", m.transcript)
	}
	// The native frame never carries messages_after; js degrades a missing or
	// non-numeric count to "?" and go degrades identically.
	m.applyEvent(event(`{"type":"compact.finished","mode":"manual"}`))
	if len(m.transcript) != 2 || !strings.Contains(m.transcript[1], "context compacted (manual, ? messages)") {
		t.Fatalf("missing message count not degraded: %#v", m.transcript)
	}
}

func TestOperationFinalizedStaysSilentOnSuccess(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"operation.finalized","operation":"git push","outcome":"succeeded","detail":"main"}`))
	if len(m.transcript) != 0 {
		t.Fatalf("successful operation announced itself: %#v", m.transcript)
	}
	m.applyEvent(event(`{"type":"operation.finalized","operation":"git push","outcome":"cancelled","detail":"interrupted by user"}`))
	m.applyEvent(event(`{"type":"operation.finalized","operation":"deploy","outcome":"failed","detail":"exit 1"}`))
	if len(m.transcript) != 2 ||
		!strings.Contains(m.transcript[0], "git push: cancelled · interrupted by user") ||
		!strings.Contains(m.transcript[1], "deploy: failed · exit 1") {
		t.Fatalf("cancelled/failed finalizations lost: %#v", m.transcript)
	}
}

// TestWidgetAndStatusKeysAreSlotScoped pins the composite `slot:key` mount
// key js's UiRenderHost uses: the same key in different slots stays
// independent instead of one mount clobbering the other.
func TestWidgetAndStatusKeysAreSlotScoped(t *testing.T) {
	m := newModel()
	m.width, m.height = 108, 36
	for _, raw := range []string{
		`{"type":"ui.render","render":{"slot":"widget","key":"gauge","body":{"type":"text","text":"widget gauge"}}}`,
		`{"type":"ui.render","render":{"slot":"status","key":"gauge","body":{"type":"text","text":"status gauge"}}}`,
	} {
		m.applyEvent(event(raw))
	}
	if len(m.surface.widgets) != 1 || len(m.surface.statuses) != 1 {
		t.Fatalf("same key in two slots collapsed: %#v %#v", m.surface.widgets, m.surface.statuses)
	}
	if strings.Join(m.surface.widgets["widget:gauge"].Lines, "|") != "widget gauge" ||
		strings.Join(m.surface.statuses["status:gauge"].Lines, "|") != "status gauge" {
		t.Fatalf("mount lost slot scoping: %#v %#v", m.surface.widgets, m.surface.statuses)
	}
	m.applyEvent(event(`{"type":"ui.render","render":{"slot":"widget","key":"gauge","body":{"type":"text","text":"widget gauge 2"}}}`))
	if strings.Join(m.surface.widgets["widget:gauge"].Lines, "|") != "widget gauge 2" ||
		strings.Join(m.surface.statuses["status:gauge"].Lines, "|") != "status gauge" {
		t.Fatalf("re-render crossed the slot boundary: %#v %#v", m.surface.widgets, m.surface.statuses)
	}
	m.applyEvent(event(`{"type":"ui.render","render":{"slot":"status","key":"gauge","body":{"type":"text","text":""}}}`))
	if len(m.surface.statuses) != 0 || len(m.surface.widgets) != 1 {
		t.Fatalf("unmount crossed the slot boundary: %#v %#v", m.surface.widgets, m.surface.statuses)
	}
	// The composite key must not break the TTL sweep either.
	m.applyEvent(event(`{"type":"ui.render","render":{"slot":"widget","key":"gauge","body":{"type":"text","text":"temporary"},"ttl_ms":10}}`))
	next, _ := m.Update(clockTick(time.Now().Add(time.Second)))
	m = next.(model)
	if len(m.surface.widgets) != 0 {
		t.Fatalf("expired widget kept its slot:key mount: %#v", m.surface.widgets)
	}
}
