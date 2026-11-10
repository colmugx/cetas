package tui

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
	"github.com/colmugx/cetas/cetas-native/internal/wire"
)

type switchRecordingHost struct {
	testHost
	names  []string
	withID map[string]string
}

func (h *switchRecordingHost) Request(_ context.Context, command string, args any) (json.RawMessage, error) {
	h.names = append(h.names, command)
	if id, ok := args.(map[string]any)["session_id"].(string); ok {
		if h.withID == nil {
			h.withID = map[string]string{}
		}
		h.withID[command] = id
	}
	return json.RawMessage("{}"), nil
}

func switchPickerModel(t *testing.T, host runtimeHost) model {
	t.Helper()
	m := newModel()
	m.host = host
	m.session = "s-current"
	m.sessionPicker = sessionPickerState{
		open:  true,
		panel: overlays.Sessions{Scope: overlays.SessionScopeCurrent},
	}
	return m
}

func TestSwitchAckRetiresPickerAndKeepsLatch(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.switchInFlight = "s-target"
	next, _ := m.Update(commandResult{name: "switch_session", payload: json.RawMessage(`{"status":"switching","target":"s-target"}`)})
	state := next.(model)
	if state.sessionPicker.open {
		t.Fatal("ack must retire the picker immediately")
	}
	if state.status != "loading session…" {
		t.Fatalf("ack status: %q", state.status)
	}
	if state.switchInFlight != "s-target" {
		t.Fatalf("ack must keep the latch until the event lands: %q", state.switchInFlight)
	}
}

func TestSessionSwitchedEventAdoptsSessionAndRestartsReplay(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.switchInFlight = "s-target"
	m.transcript = []string{"> old"}
	m.blocks = map[int]transcriptui.Block{0: {Kind: "user"}}
	// An outstanding ask of the departed session must be carried out for
	// cancellation; retireSessionPresentation returns nil without one.
	m.modalRequestID = "u-1"
	m.applyEvent(event(`{"type":"session.switched","session_id":"s-target","snapshot":{"session_id":"s-target","model":"m-2","cwd":"/elsewhere"}}`))
	if m.session != "s-target" {
		t.Fatalf("switched event must adopt the target session: %q", m.session)
	}
	if m.switchInFlight != "" {
		t.Fatal("switched event must release the choose latch")
	}
	if len(m.transcript) != 0 || len(m.blocks) != 0 {
		t.Fatal("switched event must retire the departed session's presentation")
	}
	if m.surface.model != "m-2" || m.surface.cwd != "/elsewhere" {
		t.Fatalf("switched snapshot not applied: model=%q cwd=%q", m.surface.model, m.surface.cwd)
	}
	if m.pendingSessionCmd == nil {
		t.Fatal("switched event must carry the retired asks out of applyEvent")
	}
}

func TestSessionSwitchedEventBatchReturnsReplayCommands(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.switchInFlight = "s-target"
	generation := m.replayGeneration
	next, cmd := m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"session.switched","session_id":"s-target","snapshot":{"session_id":"s-target"}}`)}})
	state := next.(model)
	if cmd == nil {
		t.Fatal("the event pump must restart the replay beside the retired asks")
	}
	if state.replayGeneration == generation {
		t.Fatal("the batch path must restart the paged replay generation")
	}
	if state.status != "ready" {
		t.Fatalf("status after switched batch: %q", state.status)
	}
	if state.pendingSessionCmd != nil {
		t.Fatal("pending session commands must be consumed exactly once")
	}
}

func TestSessionSwitchFailedClearsLatchAndReports(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.switchInFlight = "s-target"
	m.applyEvent(event(`{"type":"session.switch_failed","session_id":"s-current","target":"s-target","detail":"journal unreadable"}`))
	if m.switchInFlight != "" {
		t.Fatal("failure must release the choose latch")
	}
	if !strings.Contains(m.err, "journal unreadable") {
		t.Fatalf("failure detail lost: %q", m.err)
	}
	if m.session != "s-current" || m.status != "ready" {
		t.Fatalf("failure must leave the current session attached: %q %q", m.session, m.status)
	}
}

func TestSwitchRequestErrorReleasesLatch(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.switchInFlight = "s-target"
	next, _ := m.Update(commandResult{name: "switch_session", err: errString("queue full")})
	state := next.(model)
	if state.switchInFlight != "" {
		t.Fatal("a switch that never started server-side must release the latch")
	}
	if state.status != "ready" {
		t.Fatalf("status after failed dispatch: %q", state.status)
	}
}

func TestChooseLatchPreventsSecondSwitch(t *testing.T) {
	host := &switchRecordingHost{}
	m := switchPickerModel(t, host)
	entry := overlays.SessionEntry{ID: "s-target", Current: true}
	Resumable := true
	entry.Resumable = &Resumable
	m.switchInFlight = "s-other"
	if cmd := m.sessionPickerChoose(entry); cmd != nil {
		t.Fatal("a second choose while a switch is pending must be a no-op")
	}
	for _, name := range host.names {
		if name == "switch_session" {
			t.Fatal("latched choose still dispatched a switch")
		}
	}
	m.switchInFlight = ""
	if cmd := m.sessionPickerChoose(entry); cmd == nil {
		t.Fatal("choose must dispatch once the latch is free")
	}
}

func TestPickerPrefetchIssuesOncePerRowAndSkipsForeignRows(t *testing.T) {
	host := &switchRecordingHost{}
	m := switchPickerModel(t, host)
	same := overlays.SessionEntry{ID: "s-same", Current: true}
	foreignCwd := "/somewhere/else"
	foreign := overlays.SessionEntry{ID: "s-foreign", Cwd: &foreignCwd}
	cmd0 := m.sessionPickerPrefetch(same)
	if cmd0 == nil {
		t.Fatal("first prefetch of a same-workspace row must dispatch")
	}
	if cmd := m.sessionPickerPrefetch(same); cmd != nil {
		t.Fatal("prefetch must dedupe within one picker window")
	}
	if cmd := m.sessionPickerPrefetch(foreign); cmd != nil {
		t.Fatal("foreign rows compose on the switch path, not via prefetch")
	}
	// The deduped same-workspace request must carry the row's session id.
	if msg := cmd0(); msg == nil {
		t.Fatal("prefetch command produced no message")
	}
	if host.withID["session_prefetch"] != "s-same" {
		t.Fatalf("prefetch request id: %#v", host.withID)
	}
}

func TestUnknownAskKindIsRejectedAtIngest(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	// An unknown kind must not activate any modal state: the runtime request
	// is settled with a typed cancellation instead.
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-9","kind":"file_edit","prompt":"edit?"}`))
	if m.modal != "" || m.modalRequestID != "" || len(m.pendingUI) != 0 {
		t.Fatalf("unknown kind activated ask state: modal=%q request=%q pending=%d", m.modal, m.modalRequestID, len(m.pendingUI))
	}
	if m.pendingAskReject != "u-9" {
		t.Fatalf("reject not staged: %q", m.pendingAskReject)
	}
	// The empty-kind degenerate state (modal=="" with modalRequestID!="") is
	// the variant that used to swallow every key without an answerable ask.
	m.applyEvent(event(`{"type":"ui.request","request_id":"u-10","kind":"","prompt":"?"}`))
	if m.modalRequestID != "" {
		t.Fatalf("empty kind leaked a request id: %q", m.modalRequestID)
	}
	next, cmd := m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"ui.request","request_id":"u-9","kind":"file_edit","prompt":"edit?"}`)}})
	state := next.(model)
	if cmd == nil {
		t.Fatal("the event pump must issue the typed cancellation")
	}
	if state.pendingAskReject != "" {
		t.Fatal("staged reject must be consumed exactly once")
	}
}

func TestSwitchedEventIsExemptFromSessionFilter(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.session = "s-current"
	// The event is scoped to the target session on purpose; a filter without
	// the exemption would drop it before the adoption branch could run.
	m.applyEvent(event(`{"type":"session.switched","session_id":"s-target","snapshot":{"session_id":"s-target"}}`))
	if m.session != "s-target" {
		t.Fatalf("target-scoped switched event was dropped: %q", m.session)
	}
}

// errString keeps the error-path test independent of the harness error types.
type errString string

func (e errString) Error() string { return string(e) }

var _ = tea.Batch // keep the tea import aligned with the command assertions
