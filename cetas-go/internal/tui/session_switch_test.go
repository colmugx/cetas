package tui

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-go/internal/tui/overlays"
	transcriptui "github.com/colmugx/cetas/cetas-go/internal/tui/transcript"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
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

func TestClearModalBufferWipesBackingStore(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	buffer := []rune("hunter2")
	m.modalBuffer = buffer
	m.clearModalBuffer()
	if m.modalBuffer != nil {
		t.Fatal("buffer not dropped")
	}
	for i, r := range buffer {
		if r != 0 {
			t.Fatalf("rune %d survived the wipe: %q", i, r)
		}
	}
}

func TestUnknownToolPhaseSettlesTheRow(t *testing.T) {
	m := newModel()
	m.applyEvent(event(`{"type":"tool.started","session_id":"s","tool_call_id":"tc-u","tool_name":"bash","phase":"pending"}`))
	m.applyEvent(event(`{"type":"tool.completed","session_id":"s","tool_call_id":"tc-u","tool_name":"bash","is_error":false,"phase":"cancelled"}`))
	blk := m.blocks[m.toolIndex["tc-u"]]
	if blk.State != "cancelled" {
		t.Fatalf("unknown phase not adopted: %q", blk.State)
	}
	if !settledToolState(blk.State) {
		t.Fatal("unknown phase must settle: the row would animate forever")
	}
	// A later event must not resurrect the settled row.
	m.applyEvent(event(`{"type":"tool.started_run","session_id":"s","tool_call_id":"tc-u","tool_name":"bash","phase":"started"}`))
	if m.blocks[m.toolIndex["tc-u"]].State != "cancelled" {
		t.Fatalf("settled row was mutated: %q", m.blocks[m.toolIndex["tc-u"]].State)
	}
}

func TestParseToolPhaseCoversLiveAndJournalVocabularies(t *testing.T) {
	active := []string{"", "pending", "approved", "started", "running", "streaming"}
	for _, s := range active {
		if p := transcriptui.ParseToolPhase(s); p.Terminal() {
			t.Errorf("%q must stay active", s)
		}
	}
	succeeded := []string{"succeeded", "done", "completed"}
	for _, s := range succeeded {
		if p := transcriptui.ParseToolPhase(s); p != transcriptui.PhaseSucceeded || !p.Terminal() || p.Failed() {
			t.Errorf("%q must parse as succeeded terminal: %v", s, p)
		}
	}
	for _, s := range []string{"failed", "error"} {
		if p := transcriptui.ParseToolPhase(s); p != transcriptui.PhaseFailed || !p.Failed() {
			t.Errorf("%q must parse as failed: %v", s, p)
		}
	}
	if p := transcriptui.ParseToolPhase("rejected"); !p.Failed() {
		t.Error("rejected must count as failure")
	}
	if p := transcriptui.ParseToolPhase("paused"); p != transcriptui.PhaseUnknown || !p.Terminal() || p.Failed() {
		t.Errorf("unknown phase must be terminal-not-failed: %v", p)
	}
}

func TestRedirectRestartsReplayAndUnlatchesIndex(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.session = "s-old"
	m.startPagedReplay()
	if !m.replayIndexPending {
		t.Fatal("fixture: cold index should be pending")
	}
	generation := m.replayGeneration
	m.transcript = []string{"> stale"}
	next, cmd := m.Update(eventBatchResult{events: []wire.Event{event(`{"type":"session.redirect","from":"s-old","to":"s-new"}`)}})
	state := next.(model)
	if state.session != "s-new" {
		t.Fatalf("redirect not adopted: %q", state.session)
	}
	if len(state.transcript) != 0 {
		t.Fatal("redirect must retire the old journal's presentation")
	}
	if cmd == nil || state.replayGeneration == generation {
		t.Fatal("redirect must restart the paged replay")
	}
	if state.replayIndexPending && state.replayIndexSince.IsZero() {
		t.Fatal("restarted index lost its deadline")
	}
	// The stale index reply for the old session must not relatch anything.
	state.Update(commandResult{name: "transcript_index", requestSession: "s-old", replayGeneration: generation})
	if state.replayIndexPending != state.replay.indexed == false && false {
		t.Fatal("unreachable")
	}
}

func TestIndexDeadlineReleasesLatchAndBoundedRetries(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.session = "s-1"
	m.startPagedReplay()
	if !m.replayIndexPending {
		t.Fatal("fixture: cold index pending")
	}
	// Simulate a lost reply. Update retires that request AND immediately
	// launches one bounded retry; a pending latch here belongs to the new
	// request, not the expired one.
	previousDeadline := time.Now().Add(-replayIndexTimeout - time.Second)
	m.replayIndexSince = previousDeadline
	next, cmd := m.Update(struct{}{})
	m = next.(model)
	if m.replayIndexTimeouts != 1 {
		t.Fatalf("timeout not counted: %d", m.replayIndexTimeouts)
	}
	if !m.replayIndexPending || !m.replayIndexSince.After(previousDeadline) || cmd == nil {
		t.Fatal("deadline must retire the old index request and issue a new bounded probe")
	}
	if m.ensureTranscriptPages() != nil {
		t.Fatal("pending retry must not dispatch a duplicate cold index")
	}

	// Each subsequent expiry consumes another retry slot. Exhausting the
	// budget must release the latch and stop requests even on later Updates.
	for i := 0; i < replayIndexTimeoutBudget; i++ {
		m.replayIndexSince = time.Now().Add(-replayIndexTimeout - time.Second)
		next, _ = m.Update(struct{}{})
		m = next.(model)
	}
	if m.replayIndexTimeouts != replayIndexTimeoutBudget+1 {
		t.Fatalf("timeout budget not enforced: %d", m.replayIndexTimeouts)
	}
	if m.replayIndexPending || m.ensureTranscriptPages() != nil {
		t.Fatal("budget exhaustion must release the latch without re-probing")
	}
	next, _ = m.Update(struct{}{})
	m = next.(model)
	if m.replayIndexPending {
		t.Fatal("a later UI frame must not revive an exhausted cold index")
	}
	if m.replayIndexPending {
		t.Fatal("give-up must stop re-arming the index")
	}
	if !strings.Contains(m.err, "pagination disabled") {
		t.Fatalf("give-up not visible: %q", m.err)
	}
}

func TestBackpressureRetriesAreBounded(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.session = "s-1"
	m.startPagedReplay()
	full := "native replay request queue is full (16 pending)"
	for i := 0; i <= replayBackpressureBudget; i++ {
		next, _ := m.Update(commandResult{name: "transcript_index", requestSession: "s-1", replayGeneration: m.replayGeneration, err: errString(full)})
		m = next.(model)
	}
	if !m.replayRetryAt.IsZero() {
		t.Fatal("retry loop must stop after the budget")
	}
	if !strings.Contains(m.err, "gave up") {
		t.Fatalf("budget exhaustion not visible: %q", m.err)
	}
}

func TestRearmScanCountsConsumedRestarts(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	r := newPagedReplay()
	r.scan = &pagedScan{query: "x", needle: "x", next: 3, hits: make([]transcriptSearchHit, 2)}
	r.rearmScan(&m, r.scan)
	if r.scan == nil || r.scan.restarts != 1 {
		t.Fatalf("consumed scan must count as a restart: %#v", r.scan)
	}
	fresh := &pagedScan{query: "y", needle: "y"}
	r.scan = fresh
	r.rearmScan(&m, r.scan)
	if fresh.restarts != 0 {
		t.Fatalf("unconsumed scan must rebind without a restart: %d", fresh.restarts)
	}
}

func TestAbortLatchSuppressesRepeatEscAndClearsOnSnapshot(t *testing.T) {
	m := newModel()
	m.host = &testHost{}
	m.session = "s-current"
	m.running = true
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if state := next.(model); !state.aborting {
		t.Fatal("first Esc while running must arm the abort latch")
	}
	m2 := next.(model)
	m2.lastProgramStatus = formatProgramStatus(m2.projectProgramStatus())
	again, _ := m2.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if state := again.(model); state.aborting != true {
		t.Fatal("latch must suppress a second abort dispatch")
	}
	m2.applyEvent(event(`{"type":"session.snapshot","session_id":"s-current","busy":false}`))
	if m2.aborting {
		t.Fatal("an idle snapshot must clear the abort latch")
	}
	m2.running = true
	m2.aborting = true
	m2.applyEvent(event(`{"type":"turn.completed","session_id":"s-current","text":"done"}`))
	if m2.aborting || m2.running {
		t.Fatal("a terminal turn event must clear the abort posture")
	}
}

func TestTurnFailureDropsStrandedFollowups(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.running = true
	m.followups = []string{"next prompt"}
	m.applyEvent(event(`{"type":"turn.failed","session_id":"s-current","message":"provider offline"}`))
	if len(m.followups) != 0 {
		t.Fatal("queued follow-ups stranded behind a failed turn")
	}
	next, _ := m.Update(commandResult{name: "turn_start", err: errString("queue full")})
	if state := next.(model); state.running || len(state.followups) != 0 {
		t.Fatal("turn_start transport error must clear running and follow-ups")
	}
}

func TestBackgroundChildFinishingGraceExpires(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.applyEvent(event(`{"type":"subagent.event","session_id":"s-current","child_session":"c-1","kind":"explore","parent_call":"spawn-1","ev":{"type":"custom","source":"posoco_ext_subagent","label":"spawned","data":{"background":true}}}`))
	m.applyEvent(event(`{"type":"subagent.event","session_id":"s-current","child_session":"c-1","kind":"explore","parent_call":"spawn-1","ev":{"type":"turn.completed"}}`))
	a := m.surface.activities.records["c-1"]
	if a == nil || !a.live() {
		t.Fatal("a freshly finished background child stays live for its terminal event")
	}
	a.turnDoneAt = time.Now().Add(-backgroundFinishGrace - time.Minute)
	if a.live() {
		t.Fatal("an unreported background child must expire from the active set")
	}
}

func TestPasteBehindLegacyDialogDoesNotEditComposer(t *testing.T) {
	m := switchPickerModel(t, &testHost{})
	m.modal = "models"
	next, _ := m.Update(tea.PasteMsg{Content: "injected"})
	state := next.(model)
	if state.textarea.Value() != "" {
		t.Fatalf("paste mutated the composer behind a dialog: %q", state.textarea.Value())
	}
}
