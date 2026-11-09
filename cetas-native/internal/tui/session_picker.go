package tui

// Typed `/sessions` integration: the wire conversation around overlays.Sessions.
//
// The overlay is presentation only — it renders one page of transcript
// *metadata* and reports what the user asked for. This file owns everything
// around it: the bounded `session_catalog` request, the page anchor stack, the
// monotonic picker epoch that retires a closed picker's replies, and the rules
// that decide whether a chosen row may be resumed in this workspace at all.
//
// Paging is a bounded replace window, not accumulation: at most
// sessionPickerPageLimit rows live in the picker, one page at a time, and the
// opaque keyset anchors already visited are remembered so "previous" can
// return without refetching the whole catalog.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
)

// sessionPickerPageLimit is the row window of one page request. The parent
// pages with a keyset anchor, so the model never holds the whole catalog.
const sessionPickerPageLimit = 100

// sessionPickerDirection is what installing the requested page does to the
// page history: open/scope refresh, one page forward, or one page back.
type sessionPickerDirection int

const (
	sessionPickerFirst sessionPickerDirection = iota
	sessionPickerForward
	sessionPickerBack
)

// sessionPickerState is the model-side half of the typed picker. The overlay
// holds the rows and the scope; this holds the bounded page window around it.
type sessionPickerState struct {
	// open marks the window. It stays open behind a UiPort ask (asks are the
	// first focus owner) and until a switch actually succeeds.
	open bool
	// panel is the presentation state: scope, rows, cursor, generation.
	panel overlays.Sessions
	// cursor is the keyset anchor of the page on screen ("" is page 0).
	cursor string
	// stack is the LIFO of anchors already left, so "previous" is one opaque
	// string per visited page instead of a second copy of the catalog.
	stack []string
	// next is the server continuation anchor, "" when the page is the tail.
	next string
	// requested is the anchor of the page in flight.
	requested string
	// direction is how that page will be installed once it is accepted.
	direction sessionPickerDirection
}

// sessionCatalogPage is one `session_catalog` reply
// (cetas-console/console/native_session_catalog.mbt): a page of transcript
// metadata plus the continuation anchor. `next` is null on the last page.
type sessionCatalogPage struct {
	Scope    string                  `json:"scope"`
	Cwd      string                  `json:"cwd"`
	Items    []overlays.SessionEntry `json:"items"`
	Next     *string                 `json:"next"`
	Total    int                     `json:"total"`
	Warnings []json.RawMessage       `json:"warnings"`
	Error    string                  `json:"error"`
}

// openSessionPicker starts a current-folder picker and asks for its first
// bounded page. Opening retires any previous window, so a reply for an older
// picker is refused instead of painting the new one.
func (m *model) openSessionPicker() tea.Cmd {
	m.closeSessionPicker()
	m.sessionPicker = sessionPickerState{
		open:  true,
		panel: overlays.Sessions{Scope: overlays.SessionScopeCurrent},
	}
	return m.sessionPickerReload("", sessionPickerFirst)
}

// closeSessionPicker retires the picker and bumps the monotonic epoch. Every
// reply still in flight — including a page deferred behind a UiPort ask — is
// then refused instead of painting a window the user already dismissed.
func (m *model) closeSessionPicker() {
	m.sessionPicker = sessionPickerState{}
	m.sessionPickerEpoch++
}

// sessionPickerReload replaces the visible page with a fresh one under a new
// generation. Every page request mints its generation here, so an older reply
// cannot overwrite a newer page even inside the same picker.
func (m *model) sessionPickerReload(after string, direction sessionPickerDirection) tea.Cmd {
	action := m.sessionPicker.panel.Refresh()
	return m.sessionPickerFetch(after, direction, action.Generation)
}

// sessionPickerFetch asks for the page that starts after the anchor. The rows
// on screen are dropped: a replace window keeps exactly one page of metadata
// in memory, and the picker never accumulates the catalog page after page.
func (m *model) sessionPickerFetch(after string, direction sessionPickerDirection, generation int) tea.Cmd {
	p := &m.sessionPicker
	p.panel.Entries = nil
	p.panel.Index = 0
	p.panel.More = false
	p.next = ""
	p.requested = after
	p.direction = direction
	if direction == sessionPickerFirst {
		// A fresh page 0 (open, scope change) owns no history: the anchors of
		// the scope the user left are dropped with its rows.
		p.stack = nil
		p.cursor = ""
	}
	if m.host == nil {
		p.panel.SetError(generation, "Posoco is not connected")
		return nil
	}
	return sessionCatalogCommand(m.host, m.sessionPickerEpoch, m.session, p.panel.Scope, generation, after)
}

// sessionCatalogCommand is one bounded catalog request. The reply carries the
// picker identity it was asked for, so staleness is decided from the result
// itself and never from whatever the model happens to hold when it lands.
func sessionCatalogCommand(host runtimeHost, epoch uint64, session string, scope overlays.SessionsScope, generation int, after string) tea.Cmd {
	args := map[string]any{"scope": string(scope), "after": after, "limit": sessionPickerPageLimit}
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		payload, err := host.Request(ctx, "session_catalog", args)
		return commandResult{
			name:             "session_catalog",
			payload:          payload,
			err:              err,
			pickerEpoch:      epoch,
			pickerGeneration: generation,
			pickerScope:      scope,
			pickerSession:    session,
		}
	}
}

// sessionPickerStale reports why a catalog reply must be dropped, before any of
// it — including its error — may reach the screen: the window was closed or
// reopened, the picker has since asked for another page or scope, or the reply
// belongs to a session that is no longer attached.
func (m model) sessionPickerStale(result commandResult) bool {
	p := m.sessionPicker
	if !p.open || result.pickerEpoch != m.sessionPickerEpoch {
		return true
	}
	if result.pickerGeneration != p.panel.Generation {
		return true
	}
	if result.pickerScope != p.panel.Scope {
		return true
	}
	return result.pickerSession != m.session
}

// applySessionCatalogReply routes one catalog reply. Staleness is decided
// before generic error handling, so a late failure for a dismissed or
// superseded picker can never raise a notice or clobber a newer page.
func (m *model) applySessionCatalogReply(result commandResult) tea.Cmd {
	if m.sessionPickerStale(result) {
		return nil
	}
	p := &m.sessionPicker
	// A UiPort ask is the first focus owner in FIFO order. A page that arrives
	// while an ask is outstanding waits for it instead of installing rows
	// behind an approval; the deferred replay keeps these tags, so it is
	// refused like any other reply if the picker moved on in the meantime.
	if m.modalRequestID != "" {
		m.deferredDialogs = append(m.deferredDialogs, result)
		return nil
	}
	if result.err != nil {
		p.panel.SetError(result.pickerGeneration, result.err.Error())
		return nil
	}
	var page sessionCatalogPage
	if err := json.Unmarshal(result.payload, &page); err != nil {
		p.panel.SetError(result.pickerGeneration, "invalid session catalog reply: "+err.Error())
		return nil
	}
	if page.Error != "" {
		p.panel.SetError(result.pickerGeneration, page.Error)
		return nil
	}
	// The envelope echoes the normalized scope it answered for; a page for the
	// scope the picker has left is stale even under the current generation.
	if page.Scope != "" && overlays.SessionsScope(page.Scope) != p.panel.Scope {
		return nil
	}
	m.installSessionCatalogPage(page)
	return nil
}

// installSessionCatalogPage adopts the accepted page and moves the page
// history. The history changes only on success: a refused or failed page
// leaves the cursors exactly where they were, so retrying is honest.
func (m *model) installSessionCatalogPage(page sessionCatalogPage) {
	p := &m.sessionPicker
	if !p.panel.SetEntries(p.panel.Generation, m.sessionPageResumable(page.Items), false) {
		// The installer refused the page (over the picker's row cap) and
		// reported why; nothing was installed, so nothing moves.
		return
	}
	switch p.direction {
	case sessionPickerForward:
		p.stack = append(p.stack, p.cursor)
		p.cursor = p.requested
		p.panel.Index = 0
	case sessionPickerBack:
		if n := len(p.stack); n > 0 {
			p.stack = p.stack[:n-1]
		}
		p.cursor = p.requested
		// Walking back lands on the row the user was on when they left.
		if rows := len(p.panel.Visible()); rows > 0 {
			p.panel.Index = rows - 1
		}
	default:
		p.stack = nil
		p.cursor = ""
		p.panel.Index = 0
	}
	p.next = ""
	if page.Next != nil {
		p.next = *page.Next
	}
	p.panel.More = p.next != ""
}

// sessionPageResumable fills in the catalog's optional `resumable` decision for
// rows that arrived without one, using exactly the rules the chooser applies:
// this workspace's rows resume in place, a foreign row with a recorded
// directory resumes through the atomic cross-workspace route, and only a
// foreign row with no recorded directory has no route at all.
func (m model) sessionPageResumable(items []overlays.SessionEntry) []overlays.SessionEntry {
	yes, no := true, false
	for i := range items {
		entry := &items[i]
		if entry.Resumable != nil {
			continue
		}
		if m.sessionPickerSameCwd(*entry) {
			entry.Resumable = &yes
			continue
		}
		if _, recorded := recordedCwd(*entry); recorded {
			entry.Resumable = &yes
			continue
		}
		if entry.Reason == "" {
			entry.Reason = "no project folder recorded; cannot resume from another project"
		}
		entry.Resumable = &no
	}
	return items
}

// sessionPickerMove walks the cursor inside the bounded page and asks for the
// neighbouring page when the user pushes past one of its edges. Arrow keys and
// the wheel share it, so both stop at exactly the same boundaries; an oversized
// wheel burst saturates at the page edge instead of being replayed notch by
// notch.
func (m *model) sessionPickerMove(delta int) tea.Cmd {
	p := &m.sessionPicker
	rows := len(p.panel.Visible())
	if rows == 0 || delta == 0 {
		return nil
	}
	last := rows - 1
	at := min(max(0, p.panel.Index), last)
	if delta > 0 && at >= last && p.next != "" {
		return m.sessionPickerReload(p.next, sessionPickerForward)
	}
	if delta < 0 && at <= 0 && len(p.stack) > 0 {
		return m.sessionPickerReload(p.stack[len(p.stack)-1], sessionPickerBack)
	}
	p.panel.Index = at
	p.panel.Scroll(delta)
	return nil
}

// sessionPickerKey routes one key to the typed picker while it owns focus. The
// boundary-sensitive arrows are handled here so paging is decided before the
// overlay clamps the cursor; every other key stays with the overlay's own
// contract (tabs, enter, esc/q and the empty-scope dismissal).
func (m *model) sessionPickerKey(key string) tea.Cmd {
	switch key {
	case "up", "ctrl+p":
		return m.sessionPickerMove(-1)
	case "down", "ctrl+n":
		return m.sessionPickerMove(1)
	}
	return m.sessionPickerAction(m.sessionPicker.panel.Key(key))
}

// sessionPickerAction executes what the overlay reported.
func (m *model) sessionPickerAction(action overlays.SessionsAction) tea.Cmd {
	switch action.Kind {
	case overlays.SessionsLoad:
		// Tab/shift-tab: the other scope's rows and page history belong to the
		// scope the user just left, so both are dropped before the fetch. The
		// overlay already minted the generation for this request.
		return m.sessionPickerFetch("", sessionPickerFirst, action.Generation)
	case overlays.SessionsChoose:
		return m.sessionPickerChoose(action.Entry)
	case overlays.SessionsCancel:
		m.closeSessionPicker()
	}
	return nil
}

// sessionPickerChoose resumes the row the user picked. A row recorded in this
// workspace reuses the existing `switch_session {id}` request; a foreign row
// with a recorded folder goes through the atomic cross-workspace route below.
func (m *model) sessionPickerChoose(entry overlays.SessionEntry) tea.Cmd {
	if !m.sessionPickerSameCwd(entry) {
		return m.resumeForeignSession(entry)
	}
	if !m.sessionPicker.panel.Resumable(entry) {
		m.err = "cannot resume session: " + sessionPickerReason(entry)
		return nil
	}
	if m.host == nil {
		m.err = "Posoco is not connected"
		return nil
	}
	// The picker stays open until the switch actually succeeds: a failed
	// switch must leave the user where they were, not on a dismissed overlay.
	return request(m.host, "switch_session", map[string]any{"id": entry.ID})
}

// resumeForeignSession resumes a row recorded in another project folder. The
// console's `switch_session {id, cwd, permission}` commits the workspace
// switch and the session attach as one operation — a failure leaves this
// workspace untouched — and the inherited permission seeds a workspace this
// process has never opened, so a narrowed mode never widens back by accident.
// Background work in the current workspace keeps running. The recorded folder
// must still exist on disk; a stale recording refuses without switching.
func (m *model) resumeForeignSession(entry overlays.SessionEntry) tea.Cmd {
	cwd, ok := recordedCwd(entry)
	if !ok || cwd == "" {
		// A legacy journal with no recorded folder has nothing to resume into:
		// the bucket hash cannot be reversed, so say that instead of promising
		// a route for a project nobody can name.
		m.err = "cannot resume session: " + sessionPickerReason(entry)
		return nil
	}
	if !m.sessionPicker.panel.Resumable(entry) {
		m.err = "cannot resume session: " + sessionPickerReason(entry)
		return nil
	}
	info, err := os.Stat(cwd)
	if err != nil || !info.IsDir() {
		m.err = "cannot resume session: folder " + cwd + " no longer exists"
		return nil
	}
	if m.host == nil {
		m.err = "Posoco is not connected"
		return nil
	}
	args := map[string]any{"id": entry.ID, "cwd": cwd}
	if permission := strings.TrimSpace(m.surface.permission); permission != "" {
		args["permission"] = permission
	}
	// The picker stays open until the switch succeeds; the switch_session
	// reply path retires it, resets the replay and pages the new transcript.
	return request(m.host, "switch_session", args)
}

// recordedCwd is the project directory the transcript metadata recorded, if
// any. It is the only directory a resume may use: the row's folder slug is a
// label recovered from the bucket name and is never a path.
func recordedCwd(entry overlays.SessionEntry) (string, bool) {
	if entry.Cwd == nil {
		return "", false
	}
	cwd := strings.TrimSpace(*entry.Cwd)
	return cwd, cwd != ""
}

// sessionPickerSameCwd reports whether the chosen row belongs to the active
// workspace. Two facts are authoritative: the catalog marked the row as the
// attached session, or its transcript metadata recorded exactly this project
// directory. A current-scope page is this project's bucket by construction, so
// a legacy row without a recorded cwd is still this folder's session. The
// folder slug is a display label only and is never treated as a directory.
func (m model) sessionPickerSameCwd(entry overlays.SessionEntry) bool {
	if entry.Current {
		return true
	}
	if entry.Cwd != nil {
		return sameWorkspacePath(*entry.Cwd, m.surface.cwd)
	}
	return m.sessionPicker.panel.Scope == overlays.SessionScopeCurrent
}

// sessionPickerReason explains why a row cannot be resumed from here.
func sessionPickerReason(entry overlays.SessionEntry) string {
	if reason := strings.TrimSpace(ui.Clean(entry.Reason)); reason != "" {
		return reason
	}
	return "no folder recorded — cannot resume from here"
}

// sameWorkspacePath compares two recorded project directories without ever
// inventing one.
func sameWorkspacePath(a, b string) bool {
	a, b = strings.TrimSpace(a), strings.TrimSpace(b)
	if a == "" || b == "" {
		return false
	}
	a, b = filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}
