// Package tui hosts the Cetas terminal in Bubble Tea v2. MoonBit/Posoco
// remains the sole authority for provider, session and turn state.
package tui

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/glamour/v2"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
	"github.com/colmugx/cetas/cetas-native/internal/tui/composer"
	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"

	"github.com/colmugx/cetas/cetas-native/internal/wire"
)

type Runtime interface {
	Request(context.Context, string, any) (json.RawMessage, error)
	Events() <-chan wire.Event
	Errors() <-chan error
	Close(context.Context) error
}

type runtimeHost = Runtime
type Startup func() (Runtime, bool, error)

type clockTick time.Time

type commandResult struct {
	name             string
	payload          json.RawMessage
	err              error
	requestSession   string
	requestRevision  string
	replayGeneration uint64
	// Typed `/sessions` tags: the picker identity a session_catalog reply was
	// asked for. They are carried on the result so staleness is decided from
	// the reply itself, never from the model state it happens to land on.
	pickerEpoch      uint64
	pickerGeneration int
	pickerScope      overlays.SessionsScope
	pickerSession    string
}
type eventResult struct {
	event wire.Event
	ok    bool
}
type eventBatchResult struct {
	events []wire.Event
	closed bool
}
type errorResult struct {
	err error
	ok  bool
}
type uiPrompt struct {
	id, kind, prompt string
	options          []string
	defaultValue     json.RawMessage
}

type bootResult struct {
	host       Runtime
	needsSetup bool
	err        error
}

// Event-driven queue caps: without them a host that out-produces the user
// grows memory without bound (audit finding).
const (
	pendingUICap       = 32
	deferredDialogsCap = 64
	followupsCap       = 16
	// toolFragmentCap bounds the streamed tool-argument accumulators.
	toolFragmentCap = 256
	// Attachment-tray thumbnail geometry, in cells.
	trayThumbCols = 8
	trayThumbRows = 3

	// Turn outcomes for the program-status record (spec state names).
	turnDone   = "done"
	turnFailed = "failed"
)

type model struct {
	start               Startup
	version             string
	fragments           map[int]toolFragment
	surface             surfaceState
	host                runtimeHost
	feed                <-chan wire.Event
	textarea            composer.Model
	blocks              map[int]transcriptui.Block
	viewport            viewport.Model
	virtualScroll       *virtualTranscript
	document            documentState
	presentation        presentationFrame
	replay              *pagedReplay
	replayGeneration    uint64
	replayIndexPending  bool
	replayIndexSince    time.Time
	replayIndexTimeouts int
	replayBackpressure  int
	replayRetryAt       time.Time
	copyGeneration      uint64
	copyCancel          context.CancelFunc
	width, height       int
	transcript          []string
	searchQuery         string
	searchHits          []transcriptSearchHit
	searchActive        int
	hiddenSearchSources []hiddenTranscriptSource
	markdownRaw         map[int]string
	toolIndex           map[string]int
	markdownCache       *markdownCache
	markdownRenderer    *glamour.TermRenderer
	markdownThemeKey    string
	streaming           string
	reasoning           string
	running             bool
	// aborting marks a turn_abort in flight: Esc re-presses are ignored
	// until a snapshot or a terminal turn event settles the posture.
	aborting            bool
	needsSetup          bool
	welcomeHidden       bool
	initialReplayLoaded bool
	modal               string
	modalItems          []string
	modalValues         []string
	modalIndex          int
	modalRequestID      string
	modalPrompt         string
	modalBuffer         []rune
	pendingUI           []uiPrompt
	deferredDialogs     []commandResult
	followups           []string
	completionPrefix    string
	completionToken     string
	// completionDueAt stages the debounced completion request (see
	// autocomplete.go); the update pump fires it when typing settles.
	completionDueAt time.Time
	// completionInFlight is the request id of the outstanding completion;
	// replies carrying any other id are stale and dropped.
	completionInFlight string
	nextCompletionID   int
	// turnOutcome latches the last finished turn (turnDone/turnFailed) so
	// the OSC 7501 record reports done/error — the tab-bar signal that work
	// finished while the user was elsewhere. Any user input resets it.
	turnOutcome        string
	turnOutcomeDetail  string
	modelSlots         []overlays.ModelSlot
	modelPicker        overlays.Models
	sessionPicker      sessionPickerState
	sessionPickerEpoch uint64
	// pickerPanel memoizes the typed picker's rendered panel and its
	// composited rect, keyed on every render input (see pickerPanelKey).
	pickerPanel *pickerPanelMemo
	// switchInFlight holds the target id of a session switch whose ack
	// arrived but whose `session.switched` event has not: a second choose
	// in that window must not issue a second switch.
	switchInFlight string
	// pendingSessionCmd carries ask-cancellation commands produced while
	// reducing a `session.switched` event (applyEvent cannot return them);
	// the event pump batches it with the replay restart.
	pendingSessionCmd tea.Cmd
	// pendingAskReject settles an unsupported ui.request with a typed
	// cancellation once the event pump can issue commands.
	pendingAskReject   string
	nextPicker         string
	lastEscape         time.Time
	pendingProvider    string
	authID             string
	providerMethods    map[string][]string
	dynamicCommands    map[string]registeredCommand
	commandSession     string
	nextCommandRequest int
	// commandRequestInFlight is the request_id of the outstanding dynamic
	// command; completions that do not match it are stale and dropped.
	commandRequestInFlight string
	session                string
	status                 string
	err                    string
	presentedError         string
	clockGeneration        uint64
	clockDue               time.Time
	showThinking           bool
	showTools              bool
	// lastProgramStatus dedupes OSC 7501 reports: one frame per state change.
	lastProgramStatus string
	// focused tracks terminal focus reporting (Ghostty-class terminals):
	// unfocused turn completions become OSC 9 desktop notifications.
	focused bool
	// pendingTitle / lastTitle drive the OSC 2 terminal title; pendingNotice
	// carries one OSC 9 notification out of applyEvent.
	pendingTitle  string
	lastTitle     string
	pendingNotice string
	// pendingImages are staged image attachments (pasted from the clipboard)
	// waiting for the next submit.
	pendingImages []imageAttachment
	// kittyThumbs registers attachment-tray thumbnails, separate from the
	// transcript registry so one image can be chip now and block later.
	kittyThumbs map[string]kittyImageLayout
	// kittyImages registers inline-displayed images (base64 → layout); the
	// block renderer materializes them as unicode-placeholder rows.
	kittyImages map[string]kittyImageLayout
	// pendingKitty carries transmit+virtual-placement sequences that must
	// reach the terminal before the first frame that displays placeholders.
	pendingKitty []string
	nextKittyID  int
}

func newModel() model {
	ta := composer.New()
	ta.Placeholder = "Ask Cetas or type /help"
	ta.Prompt = "> "
	ta.SetWidth(78)
	ta.SetHeight(1)
	ta.Focus()
	renderer, renderErr := newMarkdownRenderer(80, ui.Theme{})
	vp := viewport.New(viewport.WithWidth(80), viewport.WithHeight(18))
	vp.SetWidth(80)
	vp.SetHeight(18)
	// The document supplies cell-wrapped row pages already. Rewrapping those
	// rows in viewport.View repeats ANSI/grapheme work for every scroll.
	vp.SoftWrap = false
	m := model{textarea: ta, viewport: vp, markdownRenderer: renderer, markdownCache: newMarkdownCache(markdownCacheBudget), pickerPanel: &pickerPanelMemo{}, status: "connecting to Posoco…", searchActive: -1, surface: initialSurface(), version: "0.11.0", focused: true}
	if renderErr != nil {
		m.err = "Markdown renderer initialization failed: " + renderErr.Error()
	}
	return m
}

func New(start Startup, version string) tea.Model {
	m := newModel()
	m.start = start
	m.version = version
	return m
}
func (m model) boot() tea.Msg {
	if m.start == nil {
		return bootResult{err: fmt.Errorf("runtime startup was not supplied")}
	}
	host, setup, err := m.start()
	return bootResult{host: host, needsSetup: setup, err: err}
}
func receive(events <-chan wire.Event) tea.Cmd {
	return func() tea.Msg {
		first, ok := <-events
		if !ok {
			return eventBatchResult{closed: true}
		}
		result := eventBatchResult{events: []wire.Event{first}}
		// One native command drains a bounded burst, respecting EventHub order.
		// A single Bubble Tea render then covers many rapid token deltas.
		for len(result.events) < 64 {
			select {
			case e, ok := <-events:
				if !ok {
					result.closed = true
					return result
				}
				result.events = append(result.events, e)
			default:
				return result
			}
		}
		return result
	}
}
func receiveErrors(errors <-chan error) tea.Cmd {
	return func() tea.Msg { err, ok := <-errors; return errorResult{err: err, ok: ok} }
}
func request(host runtimeHost, command string, args any) tea.Cmd {
	return requestAs(host, command, command, args)
}

// requestAs preserves the wire command while distinguishing independent UI
// intents that otherwise race on the same asynchronous reply.
func requestAs(host runtimeHost, name, command string, args any) tea.Cmd {
	var session, revision string
	if fields, ok := args.(map[string]any); ok {
		session, _ = fields["session_id"].(string)
		revision, _ = fields["revision"].(string)
	}
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		result, err := host.Request(ctx, command, args)
		return commandResult{name: name, payload: result, err: err, requestSession: session, requestRevision: revision}
	}
}

// Close releases presentation workers after Program.Run returns, including
// direct QuitMsg/context-cancellation paths that bypass Model.Update.
func (m model) Close() {
	m.cancelPagedCopy()
	m.closeHistoryMarkdown()
	if worker := m.document.markdown; worker != nil {
		worker.stop()
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.boot, tea.RequestBackgroundColor, tea.RequestForegroundColor)
}
func (m model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	if tick, ok := message.(scheduledUITick); ok {
		if tick.generation != m.clockGeneration || m.clockDue.IsZero() {
			return m, nil // An obsolete deadline cannot restart an idle timer chain.
		}
		m.clockDue = time.Time{}
		message = clockTick(tick.at)
	}
	m.presentation.deferMount = true
	m.presentation.layout = nil
	next, cmd := m.update(message)
	state := next.(model)
	state.presentation.deferMount = false
	state.presentErrorNotice()
	state.reflow()
	if page := state.ensureTranscriptPages(); page != nil {
		cmd = tea.Batch(cmd, page)
	}
	if timer := state.scheduleUIClock(time.Now()); timer != nil {
		cmd = tea.Batch(cmd, timer)
	}
	if raw := state.emitProgramStatus(); raw != nil {
		cmd = tea.Batch(cmd, raw)
	}
	if chrome := state.emitTerminalChrome(); chrome != nil {
		cmd = tea.Batch(cmd, chrome)
	}
	if len(state.pendingKitty) > 0 {
		sequences := state.pendingKitty
		state.pendingKitty = nil
		cmd = tea.Batch(cmd, tea.Raw(strings.Join(sequences, "")))
	}
	if due := state.fireCompletion(); due != nil {
		cmd = tea.Batch(cmd, due)
	}
	if state.modal == "" && state.modalRequestID == "" && len(state.deferredDialogs) > 0 {
		reply := state.deferredDialogs[0]
		state.deferredDialogs = state.deferredDialogs[1:]
		resume := func() tea.Msg { return reply }
		if cmd == nil {
			cmd = resume
		} else {
			cmd = tea.Batch(cmd, resume)
		}
	}
	view := state.renderView()
	state.presentation.snapshot = &view
	return state, cmd
}
func (m model) update(message tea.Msg) (tea.Model, tea.Cmd) {
	// Test/embedded single-event adapters share the production batch reducer.
	if single, ok := message.(eventResult); ok {
		message = eventBatchResult{events: []wire.Event{single.event}, closed: !single.ok}
		if !single.ok {
			message = eventBatchResult{closed: true}
		}
	}
	if mouse, ok := message.(tea.MouseMsg); ok {
		if m.sessionPickerFocused() {
			switch mouse.(type) {
			case tea.MouseClickMsg, tea.MouseMotionMsg, tea.MouseReleaseMsg:
				// The centred picker owns the pointer: a press or drag must not
				// select the transcript it covers.
				return m, nil
			}
		}
		if cmd, handled := m.handleTranscriptMouse(mouse); handled {
			return m, cmd
		}
	}
	switch msg := message.(type) {
	case tea.FocusMsg:
		m.focused = true
		return m, nil
	case tea.BlurMsg:
		m.focused = false
		return m, nil
	case pagedCopyResult:
		return m, m.applyPagedCopyResult(msg)
	case clockTick:
		m.surface.frame = (m.surface.frame + 1) % 10
		m.expireSurface(time.Time(msg))
		m.surface.activities.expire(time.Time(msg))
		return m, nil

	case tea.BackgroundColorMsg:
		m.surface.bg = msg.Color
		return m, nil
	case tea.ForegroundColorMsg:
		m.surface.fg = msg.Color
		return m, nil
	case tea.KeyReleaseMsg:
		return m, nil
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case bootResult:
		if msg.err != nil {
			m.status = "startup failed"
			m.err = msg.err.Error()
			return m, nil
		}
		m.host = msg.host
		m.feed = msg.host.Events()
		if msg.needsSetup {
			m.needsSetup = true
			m.status = "Choose a provider to set up Cetas Native"
			return m, tea.Batch(receive(m.feed), receiveErrors(m.host.Errors()), request(m.host, "providers", map[string]any{}))
		}
		m.status = "ready"
		return m, tea.Batch(receive(m.feed), receiveErrors(m.host.Errors()), request(m.host, "runtime_state", map[string]string{}))
	case errorResult:
		if !msg.ok {
			return m, nil
		}
		if msg.err != nil {
			m.err = msg.err.Error()
			m.status = "runtime problem"
		}
		return m, receiveErrors(m.host.Errors())
	case eventBatchResult:
		var next string
		ready := false
		switched := false
		for _, e := range msg.events {
			var meta struct {
				Type      string `json:"type"`
				Busy      bool   `json:"busy"`
				SessionID string `json:"session_id"`
			}
			_ = json.Unmarshal(e.Raw, &meta)
			m.applyEvent(e)
			if meta.Type == "infra.ready" {
				ready = true
			}
			if meta.Type == "session.switched" || meta.Type == "session.redirect" {
				switched = true
			}
			if meta.Type == "session.snapshot" && !meta.Busy && meta.SessionID == m.session && len(m.followups) > 0 && next == "" {
				next = m.followups[0]
				m.followups = m.followups[1:]
				m.running = true
			}
		}
		m.refreshTranscript()
		if msg.closed {
			m.flushAssistant()
			m.running = false
			m.aborting = false
			m.followups = nil
			m.authID = ""
			m.Close()
			m.document.markdown = nil
			m.document.live = liveMarkdown{}
			m.status = "MoonBit host stopped"
			// Terminal-owned status ends with the host: report clear once so
			// a supporting terminal drops the state before the exit restore.
			return m, tea.Raw(formatProgramStatus(programStatus{state: "clear"}))
		}
		if ready {
			return m, tea.Batch(receive(m.feed), m.startPagedReplay(), request(m.host, "commands", map[string]any{}))
		}
		if switched {
			// applyEvent already moved the model onto the target session;
			// settle the departed session's abandoned asks beside the fresh
			// paged replay and the registered-command catalog.
			retired := m.pendingSessionCmd
			m.pendingSessionCmd = nil
			m.status = "ready"
			return m, tea.Batch(receive(m.feed), retired, m.startPagedReplay(), request(m.host, "commands", map[string]any{}))
		}
		if reject := m.pendingAskReject; reject != "" {
			m.pendingAskReject = ""
			return m, tea.Batch(receive(m.feed), request(m.host, "ui_response", map[string]any{"request_id": reject, "cancelled": true, "reason": "unsupported ask kind"}))
		}
		if next != "" {
			return m, tea.Batch(receive(m.feed), request(m.host, "turn_start", map[string]any{"prompt": next, "session_id": m.session}))
		}
		return m, receive(m.feed)
	case commandResult:
		if follow, handled := m.applyPagedReply(msg); handled {
			return m, follow
		}
		if strings.HasPrefix(msg.name, "complete:") {
			// Reply identity is the request id minted at dispatch, not a
			// value snapshot: every staged token gets a fresh id, so a
			// reply that no longer matches the outstanding request is
			// stale regardless of what the editor holds now.
			// Format is "complete:<request-id>:<wire command>".
			parts := strings.SplitN(msg.name, ":", 3)
			if len(parts) != 3 || parts[1] != m.completionInFlight {
				return m, nil
			}
			msg.name = parts[2]
		}
		// A catalog reply is matched against the picker request it answers
		// before any generic error handling: a stale failure must be dropped
		// silently, and an ask keeps FIFO priority over installing its page.
		if msg.name == "session_catalog" {
			return m, m.applySessionCatalogReply(msg)
		}
		if msg.err != nil {
			m.err = msg.name + ": " + msg.err.Error()
			if msg.name == "turn_start" {
				m.running = false
				m.aborting = false
				m.followups = nil
			}
			if msg.name == "switch_session" {
				// The async switch never started server-side: release the
				// choose latch instead of waiting for a session.switched that
				// cannot come.
				m.switchInFlight = ""
				m.status = "ready"
			}
			return m, nil
		}
		// Harness can return a protocol-level error inside an otherwise valid
		// correlated response. It is not a transport failure; still render it and
		// do not accidentally treat it as successful rewind/login/turn dispatch.
		var failure struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(msg.payload, &failure) == nil && failure.Error != "" {
			m.err = msg.name + ": " + failure.Error
			if msg.name == "turn_start" {
				m.running = false
			}
			return m, nil
		}
		if m.modalRequestID != "" && opensDialog(msg.name) {
			if len(m.deferredDialogs) >= deferredDialogsCap {
				// The oldest deferred reply is by construction the stalest;
				// dropping it keeps the queue bounded without losing the
				// freshest dialog the user is about to see.
				m.deferredDialogs = m.deferredDialogs[1:]
			}
			m.deferredDialogs = append(m.deferredDialogs, msg)
			return m, nil
		}
		if msg.name == "login" {
			var started struct {
				Status   string `json:"status"`
				AuthID   string `json:"auth_id"`
				Provider string `json:"provider"`
			}
			if json.Unmarshal(msg.payload, &started) == nil && started.Status == "started" && started.AuthID != "" {
				m.authID = started.AuthID
				m.status = "authenticating " + started.Provider + " (Esc cancels)"
			}
		}
		if msg.name == "login_cancel" {
			var outcome struct {
				Cancelled bool   `json:"cancelled"`
				AuthID    string `json:"auth_id"`
			}
			if json.Unmarshal(msg.payload, &outcome) == nil && outcome.AuthID == m.authID && !outcome.Cancelled {
				m.status = "authentication already settled"
				m.authID = ""
			}
		}
		if msg.name == "models" {
			var x struct {
				Models []overlays.ModelSlot `json:"models"`
				Slots  []overlays.ModelSlot `json:"slots"`
			}
			if json.Unmarshal(msg.payload, &x) == nil {
				m.modelSlots = x.Models
				if len(m.modelSlots) == 0 {
					m.modelSlots = x.Slots
				}
				m.modal = "models"
				m.modalItems = nil
				m.modalIndex = 0
				m.modalValues = nil
				if m.nextPicker == "efforts" {
					m.modal = "efforts"
					for _, slot := range m.modelSlots {
						if slot.Active {
							for _, effort := range slot.Efforts {
								m.modalItems = append(m.modalItems, effort)
								m.modalValues = append(m.modalValues, effort)
							}
						}
					}
				} else {
					m.openModelPicker()
				}
				m.nextPicker = ""
			}
		}
		if msg.name == "file_search" {
			var data struct {
				Query   string `json:"query"`
				Entries []struct {
					Path string `json:"path"`
				} `json:"entries"`
			}
			if json.Unmarshal(msg.payload, &data) == nil && m.completionToken == "@"+data.Query && strings.HasSuffix(m.textarea.Value(), m.completionToken) {
				m.modal = "files"
				m.modalIndex = 0
				m.modalItems = nil
				m.modalValues = nil
				for _, v := range data.Entries {
					m.modalItems = append(m.modalItems, v.Path)
					m.modalValues = append(m.modalValues, v.Path)
				}
			}
		}
		if msg.name == "skills" || msg.name == "skills_browse" {
			var data struct {
				Skills []struct {
					Name        string `json:"name"`
					Description string `json:"description"`
				} `json:"skills"`
			}
			if json.Unmarshal(msg.payload, &data) == nil {
				// A delayed skills catalog must not steal focus from an approval or an
				// unrelated picker opened after the request was sent.
				if m.modal != "" {
					return m, nil
				}
				if msg.name == "skills" && (m.completionToken == "" || !strings.HasSuffix(m.textarea.Value(), m.completionToken)) {
					return m, nil
				}
				m.modal = "skills"
				if msg.name == "skills_browse" {
					m.modal = "skills_browse"
				}
				m.modalIndex = 0
				m.modalItems = nil
				m.modalValues = nil
				for _, v := range data.Skills {
					if msg.name == "skills" && !strings.Contains(strings.ToLower(v.Name), strings.ToLower(strings.TrimPrefix(m.completionToken, "$"))) {
						continue
					}
					m.modalItems = append(m.modalItems, v.Name+" "+v.Description)
					m.modalValues = append(m.modalValues, v.Name)
				}
			}
		}
		if msg.name == "rewind_points" {
			var data struct {
				Points []struct {
					MessageIndex int    `json:"message_index"`
					Preview      string `json:"preview"`
				} `json:"points"`
			}
			if json.Unmarshal(msg.payload, &data) == nil {
				m.modal = "rewind"
				m.modalIndex = 0
				m.modalItems = nil
				m.modalValues = nil
				for _, point := range data.Points {
					m.modalItems = append(m.modalItems, point.Preview)
					m.modalValues = append(m.modalValues, strconv.Itoa(point.MessageIndex))
				}
				if len(m.modalItems) == 0 {
					m.modal = ""
					m.status = "no rewind points"
				}
			}
		}
		if msg.name == "rewind_apply" {
			var data struct {
				Text      string `json:"text"`
				SessionID string `json:"session_id"`
			}
			if json.Unmarshal(msg.payload, &data) == nil {
				m.textarea.SetValue(data.Text)
				m.textarea.Focus()
				m.streaming = ""
				m.reasoning = ""
				m.running = false
				m.followups = nil
				return m, m.startPagedReplay()
			}
		}
		if msg.name == "sessions" {
			var payload struct {
				Sessions []struct {
					ID     string `json:"id"`
					Title  string `json:"title"`
					Active bool   `json:"active"`
				} `json:"sessions"`
			}
			if json.Unmarshal(msg.payload, &payload) == nil {
				m.modal = "sessions"
				m.modalIndex = 0
				m.modalItems = nil
				m.modalValues = nil
				for _, v := range payload.Sessions {
					title := v.Title
					if title == "" {
						title = v.ID
					}
					if v.Active {
						title = "● " + title
					}
					m.modalItems = append(m.modalItems, title)
					m.modalValues = append(m.modalValues, v.ID)
				}
			}
		}
		if msg.name == "providers" {
			var payload struct {
				Providers []struct {
					ID       string   `json:"id"`
					Name     string   `json:"name"`
					SignedIn bool     `json:"signed_in"`
					Methods  []string `json:"methods"`
				} `json:"providers"`
			}
			if json.Unmarshal(msg.payload, &payload) == nil {
				m.modal = "providers"
				m.modalIndex = 0
				m.modalItems = nil
				m.modalValues = nil
				m.providerMethods = map[string][]string{}
				if m.needsSetup {
					m.modalPrompt = "First-run setup — choose an authentication provider"
				}
				for _, v := range payload.Providers {
					m.providerMethods[v.ID] = append([]string(nil), v.Methods...)
					title := v.Name
					if title == "" {
						title = v.ID
					}
					if v.SignedIn {
						title += " (signed in)"
					}
					m.modalItems = append(m.modalItems, title)
					m.modalValues = append(m.modalValues, v.ID)
				}
				if m.needsSetup && len(m.modalItems) == 0 {
					m.modal = ""
					m.err = "No authentication providers are available. Check the provider configuration."
					m.modalPrompt = ""
				}
			}
		}
		if msg.name == "switch_session" || msg.name == "new_session" {
			var ack struct {
				Status string `json:"status"`
			}
			if json.Unmarshal(msg.payload, &ack) == nil && ack.Status == "switching" {
				// The runtime composes the target's agent in the background;
				// the picker's job is done and `session.switched` completes
				// the switch (retirement, snapshot, paged replay) as an event.
				m.closeSessionPicker()
				m.status = "loading session…"
				return m, nil
			}
			var payload struct {
				SessionID string `json:"session_id"`
			}
			if json.Unmarshal(msg.payload, &payload) == nil && payload.SessionID != "" {
				// A synchronous host reply (whole-switch completion): retire
				// the picker (and its epoch) so the window cannot be chosen
				// from twice, and restart the replay for the attached session.
				m.switchInFlight = ""
				m.closeSessionPicker()
				retired := m.retireSessionPresentation()
				m.session = payload.SessionID
				m.welcomeHidden = msg.name != "new_session"
				m.snapshotSurface(msg.payload)
				m.dynamicCommands = nil
				m.commandSession = ""
				m.clearTranscriptSearch()
				m.resetVirtualTranscript()
				m.transcript = nil
				m.markdownRaw = nil
				m.markdownCache.reset()
				m.toolIndex = nil
				m.streaming = ""
				m.reasoning = ""
				m.running = false
				m.followups = nil
				return m, tea.Batch(retired, m.startPagedReplay(), request(m.host, "commands", map[string]any{}))
			}
		}
		if msg.name == "switch_workspace" {
			// The picker browses one workspace's catalog: a successful
			// workspace switch retires the window it was asked for.
			m.closeSessionPicker()
		}
		if msg.name == "session_transcript" {
			m.restoreTranscript(msg.payload)
		}
		if msg.name == "commands" {
			m.installCommandCatalog(msg.payload)
		}
		if msg.name == "help" {
			content := nativeSlashHelp()
			if m.commandSession == m.session {
				for _, def := range m.dynamicCommands {
					if def.Visible && !strings.Contains(content, "/"+def.ID+" — ") {
						content += "\n/" + def.ID + " — " + def.Description
					}
				}
			}
			m.transcript = append(m.transcript, content)
			m.refreshTranscript()
		}
		if msg.name == "runtime_state" || msg.name == "switch_model" || msg.name == "select_effort" || msg.name == "set_permission" {
			m.snapshotSurface(msg.payload)
		}
		if msg.name == "runtime_state" {
			var snapshot struct {
				SessionID string `json:"session_id"`
				Status    string `json:"status"`
			}
			if json.Unmarshal(msg.payload, &snapshot) == nil && snapshot.SessionID != "" {
				firstAttach := m.session == ""
				m.session = snapshot.SessionID
				if firstAttach {
					return m, tea.Batch(m.startPagedReplay(), request(m.host, "commands", map[string]any{}))
				}
			}
		}
		return m, nil
	case WheelDeltaMsg:
		if cmd := m.wheelRoute(msg.Mouse.X, msg.Mouse.Y, msg.DeltaY); cmd != nil {
			return m, tea.Batch(cmd, msg.FlushCmd())
		}
		return m, msg.FlushCmd()
	case tea.MouseWheelMsg:
		// Embedded adapters may call Update directly without the root filter.
		// Keep the same one-row/notch contract as the production aggregate path,
		// including the pointer routing.
		switch msg.Button {
		case tea.MouseWheelUp:
			return m, m.wheelRoute(msg.X, msg.Y, -1)
		case tea.MouseWheelDown:
			return m, m.wheelRoute(msg.X, msg.Y, 1)
		}
		return m, nil
	case tea.PasteMsg:
		if m.sessionPickerFocused() {
			// The overlay owns input, so a paste cannot edit the composer it
			// covers — the same contract the legacy dialogs have.
			return m, nil
		}
		if m.modalRequestID != "" && (m.modal == "secret" || m.modal == "input") {
			m.modalBuffer = append(m.modalBuffer, []rune(msg.Content)...)
			return m, nil
		}
		if m.modal != "" {
			// No other dialog accepts a paste; letting it fall through would
			// mutate the composer (and its completion popup) behind the
			// dialog the user is looking at.
			return m, nil
		}
		if msg.Content == "" {
			// An empty bracketed paste is how a terminal reports an image on
			// the clipboard: no bytes cross stdin, so the system clipboard is
			// the only channel.
			if attachment, ok := readClipboardImage(); ok {
				m.stageImageAttachments([]imageAttachment{attachment})
				m.status = m.stagedImageSummary()
				m.lastProgramStatus = formatProgramStatus(m.projectProgramStatus())
				return m, nil
			}
		}
		// Some terminals (Ghostty among them) deliver a pasted image as its
		// file path. A paste whose whole body is one attachable image path
		// becomes an attachment instead of text the user then has to clean
		// out of the composer; anything else falls through untouched.
		if token, ok := pasteImagePath(msg.Content, m.surface.cwd); ok {
			resolved, warnings := resolveImageMentions("@"+token, m.surface.cwd)
			if len(resolved) == 1 {
				m.stageImageAttachments(resolved)
				for _, warning := range warnings {
					m.protocolNotice(warning)
				}
				m.status = m.stagedImageSummary()
				m.lastProgramStatus = formatProgramStatus(m.projectProgramStatus())
				return m, nil
			}
		}
	case tea.KeyPressMsg:
		key := msg.String()
		if m.turnOutcome != "" {
			// The done/error record has served its purpose once the user is
			// typing here again; the next report replaces it with reality.
			m.turnOutcome, m.turnOutcomeDetail = "", ""
		}
		if key == "ctrl+c" {
			return m, tea.Quit
		}
		if m.searchPanelKey(msg) {
			return m, nil
		}
		if m.modelPickerKey(key, msg.Text) {
			return m, nil
		}
		if m.completing() {
			if key == "tab" {
				key = "enter"
			}
			switch key {
			case "up", "down", "ctrl+p", "ctrl+n", "enter", "esc":
			default:
				m.closeCompletion()
			}
		}
		if m.modal != "" {
			if m.modalRequestID != "" {
				switch key {
				case "ctrl+o":
					m.surface.askExpanded = !m.surface.askExpanded
					return m, nil
				case "left":
					if m.modalIndex > 0 {
						m.modalIndex--
					}
					return m, nil
				case "right":
					if m.modalIndex+1 < len(m.modalItems) {
						m.modalIndex++
					}
					return m, nil
				case "esc":
					return m, m.answerModal(map[string]any{"cancelled": true})
				case "enter":
					switch m.modal {
					case "input", "secret":
						return m, m.answerModal(map[string]any{"text": string(m.modalBuffer)})
					case "select":
						return m, m.answerModal(map[string]any{"selected": m.modalIndex})
					case "confirm":
						if m.modalIndex == 0 {
							return m, m.answerModal(map[string]any{"yes": true})
						}
						return m, m.answerModal(map[string]any{"no": false})
					}
				case "up", "ctrl+p":
					if m.modalIndex > 0 {
						m.modalIndex--
					}
					return m, nil
				case "down", "ctrl+n":
					if m.modalIndex+1 < len(m.modalItems) {
						m.modalIndex++
					}
					return m, nil
				case "backspace":
					if (m.modal == "input" || m.modal == "secret") && len(m.modalBuffer) > 0 {
						m.modalBuffer = m.modalBuffer[:len(m.modalBuffer)-1]
					}
					return m, nil
				default:
					if (m.modal == "input" || m.modal == "secret") && msg.Text != "" {
						m.modalBuffer = append(m.modalBuffer, []rune(msg.Text)...)
					}
					return m, nil
				}
			}
			switch key {
			case "esc":
				m.modal = ""
				m.modalItems = nil
				m.modalValues = nil
			case "up", "ctrl+p":
				if m.modalIndex > 0 {
					m.modalIndex--
				}
			case "down", "ctrl+n":
				if m.modalIndex+1 < len(m.modalItems) {
					m.modalIndex++
				}
			case "enter":
				if m.modalIndex < len(m.modalValues) && (m.host != nil || m.modal == "slash" || m.modal == "skills" || m.modal == "skills_browse" || m.modal == "files" || m.modal == "questions") {
					chosen := m.modalValues[m.modalIndex]
					switch m.modal {
					case "questions":
						m.modal = ""
						m.openQuestion(chosen)
						return m, nil
					case "models":
						cmd := m.chooseModel(chosen)
						m.modal = ""
						m.modalValues = nil
						m.modalPrompt = ""
						return m, cmd
					case "sessions":
						m.modal = ""
						m.modalValues = nil
						m.switchInFlight = chosen
						return m, request(m.host, "switch_session", map[string]any{"id": chosen})
					case "providers":
						methods := m.providerMethods[chosen]
						if len(methods) > 1 {
							m.pendingProvider = chosen
							m.modal = "login_methods"
							m.modalItems = append([]string(nil), methods...)
							m.modalValues = append([]string(nil), methods...)
							m.modalIndex = 0
							return m, nil
						}
						method := ""
						if len(methods) == 1 {
							method = methods[0]
						}
						m.modal = ""
						m.modalValues = nil
						return m, request(m.host, "login", map[string]any{"provider": chosen, "method": method})
					case "login_methods":
						provider := m.pendingProvider
						m.pendingProvider = ""
						m.modal = ""
						m.modalValues = nil
						return m, request(m.host, "login", map[string]any{"provider": provider, "method": chosen})
					case "efforts":
						m.modal = ""
						m.modalValues = nil
						return m, request(m.host, "select_effort", map[string]any{"effort": chosen})
					case "rewind":
						index, err := strconv.Atoi(chosen)
						m.modal = ""
						m.modalValues = nil
						if err != nil {
							m.err = "invalid rewind index"
							return m, nil
						}
						return m, request(m.host, "rewind_apply", map[string]any{"message_index": index})
					case "slash":
						m.textarea.SetValue(m.commandInsertion(chosen))
						m.textarea.Focus()
						m.closeCompletion()
						m.completionToken = ""
						// pi-tui submits slash completions on Enter, but Tab
						// only applies them. Keep the physical key distinct
						// from the list's shared confirm navigation above.
						if msg.String() == "tab" {
							return m, nil
						}
						cmd := m.submitEditor()
						return m, cmd
					case "skills_browse":
						m.modal = ""
						m.modalItems = nil
						m.modalValues = nil
						return m, nil
					case "files", "skills":
						symbol := "@"
						if m.modal == "skills" {
							symbol = "$"
						}
						inserted := m.completionPrefix + symbol + chosen
						if !strings.HasSuffix(chosen, "/") {
							inserted += " "
						}
						m.textarea.SetValue(inserted)
						m.textarea.Focus()
						m.modal = ""
						m.modalValues = nil
						m.completionToken = ""
						return m, nil
					}
				}
				m.modal = ""
				m.modalValues = nil
			}
			return m, nil
		}
		if m.sessionPickerFocused() {
			// The typed picker is the focus owner until it closes, an ask
			// arrives or a successful switch retires it. It consumes every
			// key, so the composer underneath never receives them.
			return m, m.sessionPickerKey(key)
		}
		switch key {
		case "tab":
			value := m.textarea.Value()
			if strings.HasPrefix(value, "/") {
				choices := m.commandSuggestions(value)
				if len(choices) > 0 {
					m.modal = "slash"
					m.modalIndex = 0
					m.modalItems = nil
					m.modalValues = nil
					for _, choice := range choices {
						m.modalItems = append(m.modalItems, choice.label)
						m.modalValues = append(m.modalValues, choice.insert)
					}
				}
				return m, nil
			}
			if m.host == nil {
				return m, nil
			}
			at := strings.LastIndexAny(value, "@$")
			if at >= 0 && !strings.ContainsAny(value[at:], " \t\n") {
				m.completionPrefix = value[:at]
				m.completionToken = value[at:]
				if value[at] == '@' {
					return m, request(m.host, "file_search", map[string]any{"q": value[at+1:]})
				}
				return m, request(m.host, "skills", map[string]any{})
			}
			return m, nil
		case "ctrl+o":
			m.showTools = !m.showTools
			m.refreshTranscript()
			return m, nil
		case "ctrl+t":
			m.showThinking = !m.showThinking
			m.refreshTranscript()
			return m, nil
		case "esc":
			if m.host != nil && m.running {
				if m.aborting {
					// One abort is already in flight; re-issuing per press
					// only floods the dispatcher without a second effect.
					return m, nil
				}
				m.lastEscape = time.Time{}
				m.aborting = true
				m.status = "aborting"
				return m, request(m.host, "turn_abort", map[string]any{})
			}
			if m.host != nil && m.authID != "" {
				m.status = "cancelling authentication"
				return m, request(m.host, "login_cancel", map[string]any{"auth_id": m.authID})
			}
			if len(m.pendingImages) > 0 {
				// Staged attachments clear first; a second Esc arms rewind.
				m.clearStagedImages()
				m.status = "ready"
				return m, nil
			}
			if m.host != nil && !m.lastEscape.IsZero() && time.Since(m.lastEscape) < 500*time.Millisecond {
				m.lastEscape = time.Time{}
				return m, request(m.host, "rewind_points", map[string]any{})
			}
			m.lastEscape = time.Now()
			m.textarea.Reset()
			return m, nil
		case "pgup", "pageup":
			m.scrollTranscript(-max(1, m.viewport.Height()/2))
			return m, nil
		case "pgdown", "pagedown":
			m.scrollTranscript(max(1, m.viewport.Height()/2))
			return m, nil
		case "enter":
			cmd := m.submitEditor()
			return m, cmd
		}
	}
	var cmd tea.Cmd
	m.textarea, cmd = m.textarea.Update(message)
	if _, ok := message.(tea.KeyPressMsg); ok {
		return m, tea.Batch(cmd, m.autocomplete())
	}
	if _, ok := message.(tea.PasteMsg); ok {
		return m, tea.Batch(cmd, m.autocomplete())
	}
	return m, cmd
}

// submitEditor is shared by ordinary Enter and confirmed slash completion.
// File/skill completion deliberately never enters this submission path.
func (m *model) submitEditor() tea.Cmd {
	value := strings.TrimSpace(m.textarea.Submission())
	if value == "" {
		return nil
	}
	if m.host == nil {
		m.err = "Posoco is not connected"
		return nil
	}
	m.textarea.Remember(value)
	m.textarea.Reset()
	if strings.HasPrefix(value, "/") {
		return m.command(value)
	}
	m.appendUser(value)
	// Image attachments: @mentions resolve against the workspace, pasted
	// images ride the staged set. Warnings surface as notices; the prompt's
	// text mentions stay for provenance, exactly like the JS host.
	attachments, warnings := resolveImageMentions(value, m.surface.cwd)
	attachments = append(append([]imageAttachment{}, m.pendingImages...), attachments...)
	for _, warning := range warnings {
		m.err = warning
	}
	if len(attachments) > 0 {
		if echo := m.transcript[len(m.transcript)-1]; !strings.Contains(echo, "🖼") {
			m.transcript[len(m.transcript)-1] = echo + "  " + strings.TrimSuffix(m.stagedImageSummary(), " — Enter sends, Esc clears")
		}
		// Each attachment also becomes its own block: on Ghostty/kitty it
		// renders as inline unicode-placeholder image rows; elsewhere it
		// stays the fallback chip line.
		for _, attachment := range attachments {
			at := len(m.transcript)
			block := transcriptui.Block{Kind: "image", Text: fmt.Sprintf("🖼 %s (%s)", attachment.Label, formatImageBytes(attachment.Bytes))}
			if layout, ok := m.stageKittyImage(attachment, m.viewport.Width()-2); ok {
				block.ImageID = layout.id
				block.ImageRows = layout.rows
				m.pendingKitty = append(m.pendingKitty, layout.transmits)
			}
			m.transcript = append(m.transcript, block.Text)
			m.blocks[at] = block
			m.addHiddenSource(at, block.Text)
		}
	}
	m.pendingImages = nil
	// The tray thumbnails are superseded by the transcript image blocks
	// staged above; delete them so the same pixels do not show twice.
	for _, thumb := range m.kittyThumbs {
		m.pendingKitty = append(m.pendingKitty, kittyDeleteImage(thumb.id))
	}
	m.kittyThumbs = nil
	if m.running {
		if len(m.followups) >= followupsCap {
			m.err = "follow-up queue full; prompt dropped"
			return nil
		}
		m.followups = append(m.followups, value)
		m.status = fmt.Sprintf("queued %d follow-up(s)", len(m.followups))
		m.refreshTranscript()
		return nil
	}
	m.running = true
	m.refreshTranscript()
	args := map[string]any{"prompt": value, "session_id": m.session}
	if len(attachments) > 0 {
		wire := make([]map[string]string, 0, len(attachments))
		for _, attachment := range attachments {
			wire = append(wire, map[string]string{"media_type": attachment.MediaType, "data": attachment.Data})
		}
		args["images"] = wire
	}
	return request(m.host, "turn_start", args)
}

// dismissUI consumes a completion/cancellation event only for the indicated
// request. The native runtime can finish a UiPort coroutine independently of
// the focused Bubble Tea picker, so stale dismissals must not close the next
// question (or an unrelated model/command selector).
// clearModalBuffer wipes the typed ask input before dropping the slice: a
// kind=="secret" answer would otherwise linger in the unreachable backing
// array until the collector happens to reclaim it.
func (m *model) clearModalBuffer() {
	for i := range m.modalBuffer {
		m.modalBuffer[i] = 0
	}
	m.modalBuffer = nil
}

func (m *model) dismissUI(id string) {
	if id == "" {
		return
	}
	if id == m.modalRequestID {
		m.modal = ""
		m.modalRequestID = ""
		m.modalItems = nil
		m.modalValues = nil
		m.clearModalBuffer()
		m.modalPrompt = ""
		m.modalIndex = 0
		if len(m.pendingUI) > 0 {
			m.activateUI(m.takePendingUI())
			m.status = "waiting for user input"
		} else {
			m.status = "ready"
		}
		return
	}
	for i, req := range m.pendingUI {
		if req.id == id {
			m.pendingUI = append(m.pendingUI[:i:i], m.pendingUI[i+1:]...)
			return
		}
	}
}

func (m *model) answerModal(answer map[string]any) tea.Cmd {
	id := m.modalRequestID
	answer["request_id"] = id
	m.modal = ""
	m.modalRequestID = ""
	m.modalItems = nil
	m.clearModalBuffer()
	m.modalPrompt = ""
	if len(m.pendingUI) > 0 {
		m.activateUI(m.takePendingUI())
	}
	return request(m.host, "ui_response", answer)
}

func (m *model) takePendingUI() uiPrompt {
	next := m.pendingUI[0]
	m.pendingUI[0] = uiPrompt{}
	m.pendingUI = m.pendingUI[1:]
	if len(m.pendingUI) == 0 {
		m.pendingUI = nil
	}
	return next
}

func (m *model) activateUI(req uiPrompt) {
	m.modalRequestID = req.id
	m.modal = req.kind
	m.modalPrompt = req.prompt
	m.modalIndex = 0
	m.modalItems = append([]string(nil), req.options...)
	m.clearModalBuffer()
	m.surface.askExpanded = false
	if req.kind == "confirm" {
		m.modalItems = []string{"Yes", "No"}
		var yes bool
		if len(req.defaultValue) > 0 && json.Unmarshal(req.defaultValue, &yes) == nil && !yes {
			m.modalIndex = 1
		}
	}
	if req.kind == "select" {
		var index int
		if len(req.defaultValue) > 0 && json.Unmarshal(req.defaultValue, &index) == nil && index >= 0 && index < len(req.options) {
			m.modalIndex = index
		}
	}
	if req.kind == "input" && len(req.defaultValue) > 0 {
		var text string
		if json.Unmarshal(req.defaultValue, &text) == nil {
			m.modalBuffer = []rune(text)
		}
	}
}

func (m *model) command(value string) tea.Cmd {
	m.presentation.snapshot = nil
	if cmd, handled := m.questionCommand(value); handled {
		return cmd
	}
	parts := strings.Fields(value)
	if len(parts) == 0 {
		return nil
	}
	switch parts[0] {
	case "/exit", "/quit":
		return tea.Quit
	case "/model":
		m.nextPicker = "models"
		return request(m.host, "models", map[string]any{})
	case "/effort":
		if len(parts) > 1 {
			return request(m.host, "select_effort", map[string]any{"effort": parts[1]})
		}
		m.nextPicker = "efforts"
		return request(m.host, "models", map[string]any{})
	case "/new":
		// The backend shares switch_session, but a fresh draft must not be
		// mistaken for resuming an existing conversation in the UI.
		return requestAs(m.host, "new_session", "switch_session", map[string]any{})
	case "/login":
		if len(parts) > 1 {
			method := ""
			if len(parts) > 2 {
				method = parts[2]
			}
			return request(m.host, "login", map[string]any{"provider": parts[1], "method": method})
		}
		return request(m.host, "providers", map[string]any{})
	case "/logout":
		if len(parts) > 1 {
			return request(m.host, "logout", map[string]any{"provider": parts[1]})
		}
	case "/sessions":
		// The typed picker asks for one bounded page of session_catalog
		// metadata; the legacy whole-list `sessions` reply stays supported for
		// hosts that still answer it.
		return m.openSessionPicker()
	case "/rewind":
		return request(m.host, "rewind_points", map[string]any{})
	case "/skills":
		return requestAs(m.host, "skills_browse", "skills", map[string]any{})
	case "/compact":
		return request(m.host, "session_compact", map[string]any{})
	case "/find":
		m.findTranscript(strings.TrimSpace(strings.TrimPrefix(value, "/find")))
		return nil
	case "/find-next":
		m.navigateTranscriptSearch(false)
		return nil
	case "/find-prev":
		m.navigateTranscriptSearch(true)
		return nil
	case "/copyhistory":
		if m.replay.active() {
			first, last, err := copyHistoryRange(parts, len(m.transcript))
			if err != nil {
				m.err = err.Error()
				return nil
			}
			return m.pagedCopyRangeCommand(first-1, last-1)
		}
		text, err := m.copyHistoryCommand(parts)
		if err != nil {
			m.err = err.Error()
			return nil
		}
		return tea.SetClipboard(text)
	case "/permission":
		if len(parts) > 1 {
			return request(m.host, "set_permission", map[string]any{"mode": parts[1]})
		}
	case "/help":
		return func() tea.Msg { return commandResult{name: "help", payload: json.RawMessage(`{"ok":true}`)} }
	}
	return m.invokeDynamicCommand(value)
}

// The EventHub carries tool results as text and auth.login outcomes as
// structured JSON. Decoding the entire event through a string "result" field
// rejected valid auth outcomes before the type switch even ran.
func toolResultText(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var value string
	if json.Unmarshal(raw, &value) == nil {
		return ui.SanitizeSGR(value)
	}
	return ui.SanitizeSGR(string(raw))
}

func (m *model) applyEvent(e wire.Event) {
	// Direct/embedded event injection is also a presentation mutation; it
	// cannot reuse chrome from a previous Update's completed layout.
	m.presentation.layout = nil
	var frame struct {
		Type       string          `json:"type"`
		Text       string          `json:"text"`
		Delta      string          `json:"delta"`
		Token      string          `json:"token"`
		Message    string          `json:"message"`
		ToolName   string          `json:"tool_name"`
		ToolCallID string          `json:"tool_call_id"`
		Result     json.RawMessage `json:"result"`
		IsError    bool            `json:"is_error"`
		Title      string          `json:"title"`
		Entries    []struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		} `json:"entries"`
		SessionID string          `json:"session_id"`
		RequestID string          `json:"request_id"`
		Kind      string          `json:"kind"`
		Prompt    string          `json:"prompt"`
		Options   []string        `json:"options"`
		Slot      string          `json:"slot"`
		Lines     []string        `json:"lines"`
		Default   json.RawMessage `json:"default"`
		Busy      bool            `json:"busy"`
		From      string          `json:"from"`
		To        string          `json:"to"`
	}
	if err := json.Unmarshal(e.Raw, &frame); err != nil {
		m.err = "invalid event: " + err.Error()
		return
	}
	if frame.SessionID != "" {
		if m.session == "" {
			m.session = frame.SessionID
		}
		// Do not let another running session mutate the visible transcript.
		// Host-level lifecycle facts (async switch completion) are exempt:
		// they are emitted scoped to the *target* session on purpose.
		if frame.SessionID != m.session && frame.Type != "auth.login" && frame.Type != "auth.cancelled" && frame.Type != "session.switched" && frame.Type != "session.switch_failed" {
			return
		}
	}
	if m.activityEvent(frame.Type, e.Raw) {
		return
	}
	if m.surfaceEvent(frame.Type, e.Raw) {
		return
	}
	if m.projectToolEvent(frame.Type, e.Raw) {
		if len(m.toolIndex) > 0 || len(m.fragments) > 0 {
			m.welcomeHidden = true
		}
		return
	}
	switch frame.Type {
	case "infra.error":
		var diagnostic struct {
			Detail string `json:"detail"`
		}
		if err := json.Unmarshal(e.Raw, &diagnostic); err != nil {
			m.err = "invalid native runtime diagnostic: " + err.Error()
		} else if diagnostic.Detail != "" {
			m.err = "Native runtime: " + diagnostic.Detail
		} else {
			m.err = "Native runtime reported an error without detail"
		}
	case "infra.ready":
		var data struct {
			Snapshot struct {
				SessionID string `json:"session_id"`
			} `json:"snapshot"`
		}
		if json.Unmarshal(e.Raw, &data) == nil && data.Snapshot.SessionID != "" {
			m.needsSetup = false
			m.session = data.Snapshot.SessionID
			m.requestTitle()
			m.status = "ready"
			m.err = ""
			m.modal = ""
			m.modalPrompt = ""
			m.modalValues = nil
		}
	case "infra.boot.progress":
		// Live startup feedback while the runtime composes in the background;
		// the terminal paints the phase instead of a static connecting line.
		var data struct {
			Phase string `json:"phase"`
			MS    int64  `json:"ms"`
		}
		if json.Unmarshal(e.Raw, &data) == nil && data.Phase != "" && !m.needsSetup {
			if data.Phase == "composed" {
				m.status = fmt.Sprintf("connected in %d ms", data.MS)
			} else {
				m.status = "connecting: " + data.Phase + "…"
			}
		}
	case "infra.setup_failed":
		m.needsSetup = true
		m.status = "Provider setup incomplete"
		m.err = "Authentication saved, but no usable model is configured. Choose another provider or configure a model, then restart."
	case "command.completed":
		m.handleCommandCompletion(e.Raw)
	case "turn.accepted", "turn.started":
		m.welcomeHidden = true
		m.fragments = nil
		m.running = true
		m.status = "working"
	case "assistant.text_delta":
		delta := frame.Delta
		if delta == "" {
			delta = frame.Text
		}
		if delta == "" {
			delta = frame.Token
		}
		if delta != "" {
			m.welcomeHidden = true
		}
		m.streaming += delta
	case "assistant.reasoning_delta":
		if m.streaming != "" {
			m.flushAssistant()
		}
		delta := frame.Delta
		if delta == "" {
			delta = frame.Text
		}
		if delta == "" {
			delta = frame.Token
		}
		if delta != "" {
			m.welcomeHidden = true
		}
		m.reasoning += delta
	case "turn.completed":
		text := m.streaming
		if text == "" {
			text = frame.Text
		}
		m.streaming = text
		m.flushAssistant()

		m.streaming = ""
		m.reasoning = ""
		m.running = false
		m.aborting = false
		m.status = "ready"
		m.turnOutcome, m.turnOutcomeDetail = turnDone, "Finished"
		m.requestNotice("Cetas: turn completed")
	case "turn.failed":
		m.flushAssistant()
		m.transcript = append(m.transcript, "Error: "+ui.SanitizeSGR(frame.Message))
		m.streaming = ""
		m.reasoning = ""
		m.running = false
		m.aborting = false
		// Queued follow-ups waited for an idle snapshot that a failed turn
		// never produces; keeping them strands prompts forever.
		if len(m.followups) > 0 {
			m.followups = nil
		}
		m.status = "failed"
		m.turnOutcome = turnFailed
		m.turnOutcomeDetail = ui.SanitizeSGR(frame.Message)
		if m.turnOutcomeDetail == "" {
			m.turnOutcomeDetail = "Turn failed"
		}
		m.requestNotice("Cetas: turn failed")
	case "session.redirect":
		if frame.From == m.session && frame.To != "" {
			// The picker browses one session's catalog with at most one switch
			// in flight; a redirect retires the window it was asked from.
			m.closeSessionPicker()
			// A rewritten journal (compaction redirect) is a new document:
			// adopt the id AND retire the old presentation, exactly like a
			// switch. Skipping the retirement left the in-flight index reply
			// stale-dropped before it could clear replayIndexPending,
			// latching pagination dead until the next switch.
			m.pendingSessionCmd = m.retireSessionPresentation()
			m.session = frame.To
			m.dynamicCommands = nil
			m.commandSession = ""
			m.clearTranscriptSearch()
			m.resetVirtualTranscript()
			m.transcript = nil
			m.markdownRaw = nil
			m.markdownCache.reset()
			m.toolIndex = nil
			m.streaming = ""
			m.reasoning = ""
			m.running = false
			m.followups = nil
			m.requestTitle()
		}
		m.switchInFlight = ""
		m.status = "session redirected"
	case "session.switched":
		// Completion of the async `switch_session` ack: the runtime has
		// composed and attached the target session. applyEvent cannot return
		// commands, so the ask-cancellation batch rides pendingSessionCmd and
		// the event pump restarts the paged replay beside it.
		var data struct {
			SessionID string          `json:"session_id"`
			Fresh     bool            `json:"fresh"`
			Snapshot  json.RawMessage `json:"snapshot"`
		}
		if err := json.Unmarshal(e.Raw, &data); err != nil || data.SessionID == "" {
			m.err = "invalid session.switched event"
			return
		}
		m.switchInFlight = ""
		m.aborting = false
		m.pendingSessionCmd = m.retireSessionPresentation()
		m.session = data.SessionID
		m.requestTitle()
		// A brand-new session shows the empty-start welcome; resuming a
		// journal keeps working content on screen.
		m.welcomeHidden = !data.Fresh
		m.dynamicCommands = nil
		m.commandSession = ""
		m.clearTranscriptSearch()
		m.resetVirtualTranscript()
		m.transcript = nil
		m.markdownRaw = nil
		m.markdownCache.reset()
		m.toolIndex = nil
		m.streaming = ""
		m.reasoning = ""
		m.running = false
		m.followups = nil
		if len(data.Snapshot) > 0 {
			m.snapshotSurface(data.Snapshot)
		}
		m.status = "loading transcript…"
	case "session.switch_failed":
		var data struct {
			Target string `json:"target"`
			Detail string `json:"detail"`
		}
		m.switchInFlight = ""
		m.status = "ready"
		if json.Unmarshal(e.Raw, &data) == nil && data.Detail != "" {
			m.err = "switch_session: " + data.Detail
		} else {
			m.err = "switch_session failed"
		}
	case "session.snapshot":
		m.running = frame.Busy
		// The runtime's busy flag is authoritative: a snapshot settles any
		// outstanding abort posture either way.
		m.aborting = m.aborting && frame.Busy
	case "ui.request":
		if frame.RequestID == "" {
			m.err = "ui.request missing request_id"
			return
		}
		switch frame.Kind {
		case "input", "secret", "select", "confirm":
		default:
			// An unknown kind used to produce a modal no key branch could
			// answer, parking the runtime coroutine forever; the empty kind
			// variant was worse — a modalRequestID with no modal, which the
			// key router does not route to the ask branch at all. Reject at
			// ingest: settle the request with a typed cancellation and keep
			// the composer usable.
			m.err = "unsupported ui.request kind: " + strconv.Quote(frame.Kind)
			m.pendingAskReject = frame.RequestID
			return
		}
		prompt := uiPrompt{id: frame.RequestID, kind: frame.Kind, prompt: frame.Prompt, options: frame.Options, defaultValue: frame.Default}
		if m.modalRequestID != "" {
			if len(m.pendingUI) >= pendingUICap {
				// An event-driven queue must not grow without bound: settle
				// the overflow ask immediately instead of stacking it.
				m.err = "ask queue full; request cancelled"
				m.pendingAskReject = frame.RequestID
				return
			}
			m.pendingUI = append(m.pendingUI, prompt)
		} else {
			m.activateUI(prompt)
		}
		m.status = "waiting for user input"
	case "ui.dismiss":
		m.dismissUI(frame.RequestID)
	case "auth.cancelled":
		var payload struct {
			AuthID string `json:"auth_id"`
		}
		if json.Unmarshal(e.Raw, &payload) == nil && payload.AuthID != "" && payload.AuthID == m.authID {
			m.authID = ""
			m.err = ""
			m.status = "authentication cancelled"
		}
	case "auth.login":
		// Login outcomes are provider-neutral and intentionally contain no
		// credentials. Never dump the raw result into the transcript or errors.
		var result struct {
			Type     string `json:"type"`
			Feedback string `json:"feedback"`
			Error    string `json:"error"`
		}
		var payload struct {
			Provider string          `json:"provider"`
			AuthID   string          `json:"auth_id"`
			Result   json.RawMessage `json:"result"`
		}
		// A cancelled or replaced task must not mutate the visible login state.
		if payloadErr := json.Unmarshal(e.Raw, &payload); payloadErr != nil {
			return
		}
		if payload.AuthID != "" && payload.AuthID != m.authID {
			return
		}
		m.authID = ""
		if json.Unmarshal(payload.Result, &result) != nil {
			m.err = "authentication returned an invalid result"
			m.status = "authentication failed"
		} else if result.Type == "success" {
			m.err = ""
			if m.needsSetup {
				m.status = "signed in to " + payload.Provider + "; initializing Agent…"
			} else {
				m.status = "signed in to " + payload.Provider
			}
		} else {
			m.status = "authentication failed"
			// Do not echo arbitrary provider diagnostics: a provider may include the
			// submitted API key in its error detail.
			m.err = "login failed for " + payload.Provider
		}

	}
}

func (m *model) appendAssistant(text string) {
	if m.markdownRaw == nil {
		m.markdownRaw = make(map[int]string)
	}
	idx := len(m.transcript)
	m.transcript = append(m.transcript, text)
	m.markdownRaw[idx] = text
	if m.reasoning != "" {
		if m.blocks == nil {
			m.blocks = make(map[int]transcriptui.Block)
		}
		m.blocks[idx] = transcriptui.Block{Kind: "assistant", Reasoning: m.reasoning}
		m.addHiddenSource(idx, "Thinking: "+m.reasoning)
	}
}
