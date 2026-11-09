package tui

// Integration tests for the typed `/sessions` picker. They drive the real
// request/reply path: the model builds a bounded `session_catalog` request, a
// host answers with a page in the consoler's wire shape
// (cetas-console/console/native_session_catalog.mbt), and the model installs or
// refuses it. Nothing here re-tests overlays.Sessions itself; these cases pin
// the model-side contract (epochs, paging, focus and resume routing).

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
)

// sessionCatalogHost emulates the console's bounded catalog route from an
// in-memory list and records every request, so a case can assert what the TUI
// actually asked for — including the limit it never exceeds.
type sessionCatalogHost struct {
	testHost
	total    int
	cwd      string
	now      time.Time
	requests []sessionCatalogCall
}

type sessionCatalogCall struct {
	command string
	args    map[string]any
}

func (h *sessionCatalogHost) Request(_ context.Context, command string, args any) (json.RawMessage, error) {
	fields, _ := args.(map[string]any)
	h.requests = append(h.requests, sessionCatalogCall{command: command, args: fields})
	if command != "session_catalog" {
		return json.RawMessage(`{}`), nil
	}
	scope, _ := fields["scope"].(string)
	after, _ := fields["after"].(string)
	limit, _ := fields["limit"].(int)
	start, err := h.pageStart(after)
	if err != nil {
		return json.RawMessage(`{"error":"invalid session catalog cursor"}`), nil
	}
	end := min(start+max(0, limit), h.total)
	items := make([]overlays.SessionEntry, 0, end-start)
	for i := start; i < end; i++ {
		items = append(items, h.entry(i))
	}
	page := map[string]any{"scope": scope, "cwd": h.cwd, "items": items, "total": h.total}
	if end < h.total && end > start {
		page["next"] = h.anchor(end - 1)
	}
	raw, err := json.Marshal(page)
	return raw, err
}

// anchor is the console's opaque keyset anchor for entry i: the stringified
// [modifiedMs, bucket, id] sort tuple of that row.
func (h *sessionCatalogHost) anchor(index int) string {
	entry := h.entry(index)
	raw, err := json.Marshal([]any{float64(entry.ModifiedAt), entry.Bucket, entry.ID})
	if err != nil {
		return ""
	}
	return string(raw)
}

// pageStart mirrors the console's keyset rule: the first row strictly after
// the anchor in page order (newest first, then identity ascending).
func (h *sessionCatalogHost) pageStart(after string) (int, error) {
	if after == "" {
		return 0, nil
	}
	var parts []any
	if err := json.Unmarshal([]byte(after), &parts); err != nil || len(parts) != 3 {
		return 0, fmt.Errorf("invalid anchor")
	}
	ms, _ := parts[0].(float64)
	bucket, _ := parts[1].(string)
	id, _ := parts[2].(string)
	for i := 0; i < h.total; i++ {
		entry := h.entry(i)
		if float64(entry.ModifiedAt) < ms {
			return i, nil
		}
		if float64(entry.ModifiedAt) == ms {
			if entry.Bucket > bucket || (entry.Bucket == bucket && entry.ID > id) {
				return i, nil
			}
		}
	}
	return h.total, nil
}

// entry is one same-folder catalog row: recorded cwd, title, size and mtime.
// The base time is frozen on first use so anchors computed at reply time and
// assertion time describe the same row.
func (h *sessionCatalogHost) entry(index int) overlays.SessionEntry {
	if h.now.IsZero() {
		h.now = time.Now()
	}
	cwd := h.cwd
	return overlays.SessionEntry{
		ID:         fmt.Sprintf("2026-08-30T10:00:00_%08x", index),
		Bucket:     "session_demo_aaaaaaaaaaaa",
		Title:      fmt.Sprintf("session %02d", index),
		Cwd:        &cwd,
		Folder:     "demo",
		SizeBytes:  int64(2048 * (index + 1)),
		ModifiedAt: h.now.Add(-time.Duration(index+1) * time.Minute).UnixMilli(),
	}
}

// catalogs is the catalog requests the host received, in order.
func (h *sessionCatalogHost) catalogs() []sessionCatalogCall {
	var calls []sessionCatalogCall
	for _, call := range h.requests {
		if call.command == "session_catalog" {
			calls = append(calls, call)
		}
	}
	return calls
}

// commands is every command the TUI sent through this host.
func (h *sessionCatalogHost) commands() []string {
	out := make([]string, 0, len(h.requests))
	for _, call := range h.requests {
		out = append(out, call.command)
	}
	return out
}

func (h *sessionCatalogHost) sent(command string) bool {
	for _, name := range h.commands() {
		if name == command {
			return true
		}
	}
	return false
}

// sessionPickerModel is a sized model attached to one session and workspace.
func sessionPickerModel(t *testing.T, host runtimeHost) model {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.host = host
	m.session = "s-1"
	m.surface.cwd = "/workspace/demo"
	out := &m
	t.Cleanup(func() { out.Close() })
	return m
}

// sessionRequest runs the command a step produced and returns the single
// catalog request it carried, unwrapping the batch the wheel path wraps it in.
func sessionRequest(t *testing.T, cmd tea.Cmd) commandResult {
	t.Helper()
	if cmd == nil {
		t.Fatal("no catalog request was issued")
	}
	var found []commandResult
	var walk func(tea.Cmd)
	walk = func(next tea.Cmd) {
		if next == nil {
			return
		}
		switch message := next().(type) {
		case tea.BatchMsg:
			for _, child := range message {
				walk(child)
			}
		case commandResult:
			found = append(found, message)
		}
	}
	walk(cmd)
	if len(found) != 1 || found[0].name != "session_catalog" {
		t.Fatalf("expected one session_catalog request, got %#v", found)
	}
	return found[0]
}

// wheelOver sends one coalesced wheel notch with the pointer over the centre of
// the picker panel it painted.
func wheelOver(t *testing.T, m *model, delta int) tea.Cmd {
	t.Helper()
	_, left, top, width, height := m.overlayPanel()
	if width == 0 || height == 0 {
		t.Fatal("the picker panel reported no composited geometry")
	}
	next, cmd := m.Update(WheelDeltaMsg{Mouse: tea.Mouse{X: left + width/2, Y: top + height/2}, DeltaY: delta})
	*m = next.(model)
	return cmd
}

// sessionReply is the reply a host sends for the picker's current request: the
// tags are the ones the request carried.
func sessionReply(m model, payload string) commandResult {
	return commandResult{
		name:             "session_catalog",
		payload:          json.RawMessage(payload),
		pickerEpoch:      m.sessionPickerEpoch,
		pickerGeneration: m.sessionPicker.panel.Generation,
		pickerScope:      m.sessionPicker.panel.Scope,
		pickerSession:    m.session,
	}
}

// sessionPayload is one page envelope in the native catalog's wire shape.
func sessionPayload(t *testing.T, scope string, items []overlays.SessionEntry, next *string) string {
	t.Helper()
	page := map[string]any{"scope": scope, "cwd": "/workspace/demo", "items": items, "total": len(items)}
	if next != nil {
		page["next"] = *next
	}
	raw, err := json.Marshal(page)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// containsAny reports whether text holds any of the wanted fragments.
func containsAny(text string, wanted []string) bool {
	for _, want := range wanted {
		if strings.Contains(text, want) {
			return true
		}
	}
	return false
}

// boolValue is the wire's explicit resumable decision in pointer form.
func boolValue(v bool) *bool { return &v }

// sessionRows are n same-folder rows, oldest last.
func sessionRows(host *sessionCatalogHost, from, count int) []overlays.SessionEntry {
	rows := make([]overlays.SessionEntry, 0, count)
	for i := from; i < from+count; i++ {
		rows = append(rows, host.entry(i))
	}
	return rows
}

// openTypedSessionPicker opens the picker through `/sessions` and installs the
// first page the host answers with.
func openTypedSessionPicker(t *testing.T, m *model) model {
	t.Helper()
	next, _ := m.Update(tea.KeyPressMsg{})
	*m = next.(model)
	cmd := m.command("/sessions")
	if !m.sessionPicker.open {
		t.Fatal("/sessions did not open the typed picker")
	}
	result := sessionRequest(t, cmd)
	next, _ = m.Update(result)
	return next.(model)
}

// press sends one key through the real Update path and keeps the state.
func press(t *testing.T, m *model, code rune) tea.Cmd {
	t.Helper()
	next, cmd := m.Update(tea.KeyPressMsg{Code: code})
	*m = next.(model)
	return cmd
}

// TestSessionPickerOpensWithBoundedCurrentScopePage pins the open request: one
// `session_catalog` page for the current folder, cursor 0, limit 100, tagged
// with the picker epoch, generation, scope and session.
func TestSessionPickerOpensWithBoundedCurrentScopePage(t *testing.T) {
	host := &sessionCatalogHost{total: 3, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	cmd := m.command("/sessions")
	if !m.sessionPicker.open {
		t.Fatal("/sessions did not open the typed picker")
	}
	if got := m.sessionPicker.panel.Scope; got != overlays.SessionScopeCurrent {
		t.Fatalf("open scope = %q, want the current folder", got)
	}
	result := sessionRequest(t, cmd)
	calls := host.catalogs()
	if len(calls) != 1 {
		t.Fatalf("open issued %d catalog requests", len(calls))
	}
	if scope := calls[0].args["scope"]; scope != "current" {
		t.Fatalf("open scope = %v, want current", scope)
	}
	if after := calls[0].args["after"]; after != "" {
		t.Fatalf("open anchor = %v, want page 0", after)
	}
	if limit := calls[0].args["limit"]; limit != sessionPickerPageLimit {
		t.Fatalf("open limit = %v, want %d", limit, sessionPickerPageLimit)
	}
	if result.pickerEpoch != m.sessionPickerEpoch || result.pickerGeneration != m.sessionPicker.panel.Generation {
		t.Fatalf("open reply tags do not match the request: %#v", result)
	}
	if result.pickerScope != overlays.SessionScopeCurrent || result.pickerSession != "s-1" {
		t.Fatalf("open reply scope/session tags: %q %q", result.pickerScope, result.pickerSession)
	}
	next, _ := m.Update(result)
	m = next.(model)
	if !m.sessionPicker.open || len(m.sessionPicker.panel.Entries) != 3 {
		t.Fatalf("page was not installed: %d rows", len(m.sessionPicker.panel.Entries))
	}
	if selected, ok := m.sessionPicker.panel.Selected(); !ok || selected.Title != "session 00" {
		t.Fatalf("cursor did not land on the first row: %#v", selected)
	}
}

// TestSessionPickerRendersTypedRowsWithinThePanel pins the typed overlay: the
// scope tabs, the title, the folder, the age, the size, the current-session
// marker and the explicit refusal for a row that cannot be resumed — all
// bounded to the terminal box.
func TestSessionPickerRendersTypedRowsWithinThePanel(t *testing.T) {
	host := &sessionCatalogHost{total: 0, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m.width, m.height = 140, 36
	m.resize()
	cmd := m.command("/sessions")
	sessionRequest(t, cmd)

	foreignFolder := "other-project"
	rows := []overlays.SessionEntry{{
		ID: "2026-08-30T10:00:00_00000000", Bucket: "session_demo_aaaaaaaaaaaa",
		Title: "resume me", Folder: "demo", SizeBytes: 2048,
		ModifiedAt: time.Now().Add(-3 * time.Minute).UnixMilli(), Current: true,
	}}
	// A foreign legacy row: no recorded cwd, so the folder is a slug only and
	// the catalog reports it as not resumable from here.
	unresumable := false
	rows = append(rows, overlays.SessionEntry{
		ID: "2026-08-29T10:00:00_00000001", Bucket: "session_other_bbbbbbbbbbbb",
		Title: "elsewhere", Folder: foreignFolder, SizeBytes: 5 * 1024 * 1024,
		ModifiedAt: time.Now().Add(-30 * time.Hour).UnixMilli(),
		Resumable:  &unresumable,
		Reason:     "no project folder recorded; cannot resume from another project",
	})
	reply := sessionReply(m, sessionPayload(t, "all", rows, nil))
	m.sessionPicker.panel.Scope = overlays.SessionScopeAll
	reply.pickerScope = overlays.SessionScopeAll
	next, _ := m.Update(reply)
	m = next.(model)

	view := m.View().Content
	for _, want := range []string{"Sessions", "Current Folder", "[All]", "resume me", "2.0 KB", "5.0 MB", "d ago", "current", "no project folder recorded"} {
		if !strings.Contains(view, want) {
			t.Fatalf("picker overlay is missing %q:\n%s", want, view)
		}
	}
	lines := strings.Split(view, "\n")
	if len(lines) > m.height {
		t.Fatalf("picker painted %d lines into a %d-line terminal", len(lines), m.height)
	}
	for _, line := range lines {
		if width := ansi.StringWidth(line); width > m.width {
			t.Fatalf("picker line overflows the terminal (%d > %d): %q", width, m.width, line)
		}
	}
	// A full page of rows is still painted inside the terminal box: the panel
	// window follows the height instead of growing with the catalog.
	m.width, m.height = 80, 24
	m.resize()
	m.sessionPicker.panel.Scope = overlays.SessionScopeCurrent
	full := sessionReply(m, sessionPayload(t, "current", sessionRows(host, 0, sessionPickerPageLimit), nil))
	next, _ = m.Update(full)
	m = next.(model)
	painted := strings.Split(m.View().Content, "\n")
	if len(painted) > m.height {
		t.Fatalf("a full page painted %d lines into a %d-line terminal", len(painted), m.height)
	}
	if !strings.Contains(m.View().Content, "tab folder scope") {
		t.Fatal("a full page dropped the picker footer")
	}

	// A tiny terminal still gets a bounded panel instead of a crash or overflow.
	m.width, m.height = 18, 6
	m.resize()
	for _, line := range strings.Split(m.View().Content, "\n") {
		if width := ansi.StringWidth(line); width > 18 {
			t.Fatalf("small-terminal picker overflow: %q", line)
		}
	}
}

// TestSessionPickerTabClearsEntriesAndRejectsTheOldPage pins the scope refresh:
// Tab drops the rows and the page history of the scope the user left, asks for
// page 0 of the new scope, and refuses the reply that was already in flight.
func TestSessionPickerTabClearsEntriesAndRejectsTheOldPage(t *testing.T) {
	host := &sessionCatalogHost{total: 250, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)
	if len(m.sessionPicker.panel.Entries) != sessionPickerPageLimit {
		t.Fatalf("first page = %d rows", len(m.sessionPicker.panel.Entries))
	}
	m.sessionPicker.stack = []string{"", host.anchor(sessionPickerPageLimit - 1)}
	m.sessionPicker.cursor = host.anchor(sessionPickerPageLimit - 1)
	stale := sessionReply(m, sessionPayload(t, "current", sessionRows(host, 0, 2), nil))

	cmd := press(t, &m, tea.KeyTab)
	if scope := m.sessionPicker.panel.Scope; scope != overlays.SessionScopeAll {
		t.Fatalf("Tab left the scope at %q", scope)
	}
	if len(m.sessionPicker.panel.Entries) != 0 {
		t.Fatalf("Tab kept %d rows of the previous scope", len(m.sessionPicker.panel.Entries))
	}
	if len(m.sessionPicker.stack) != 0 || m.sessionPicker.cursor != "" {
		t.Fatalf("Tab kept the page history: stack=%v cursor=%q", m.sessionPicker.stack, m.sessionPicker.cursor)
	}
	request := sessionRequest(t, cmd)
	if request.pickerScope != overlays.SessionScopeAll || request.pickerGeneration <= stale.pickerGeneration {
		t.Fatalf("scope refresh did not mint a newer generation: %#v / stale %#v", request, stale)
	}

	// The in-flight reply for the scope just left is refused before anything,
	// including its failure, reaches the model.
	next, _ := m.Update(stale)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 0 {
		t.Fatalf("stale scope page painted the cleared picker: %d rows", len(m.sessionPicker.panel.Entries))
	}
	staleError := stale
	staleError.payload = nil
	staleError.err = fmt.Errorf("stale current-folder failure")
	next, _ = m.Update(staleError)
	m = next.(model)
	if m.err != "" || m.sessionPicker.panel.Err != "" {
		t.Fatalf("stale failure reached the UI: err=%q panel=%q", m.err, m.sessionPicker.panel.Err)
	}

	next, _ = m.Update(sessionReply(m, sessionPayload(t, "all", sessionRows(host, 0, 2), nil)))
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 2 {
		t.Fatalf("current-scope reply was not installed: %d rows", len(m.sessionPicker.panel.Entries))
	}
	// A reply for the wrong scope is refused even under the live generation.
	mismatched := sessionReply(m, sessionPayload(t, "current", sessionRows(host, 0, 5), nil))
	mismatched.pickerScope = overlays.SessionScopeCurrent
	next, _ = m.Update(mismatched)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 2 {
		t.Fatalf("a current-scope reply replaced the all-scope page: %d rows", len(m.sessionPicker.panel.Entries))
	}
}

// TestSessionPickerPagesWithinABoundedWindow pins paging: the window never
// exceeds one page, forward/back move by cursor instead of accumulating rows,
// and both stop when the catalog has no neighbour.
func TestSessionPickerPagesWithinABoundedWindow(t *testing.T) {
	host := &sessionCatalogHost{total: 250, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)

	// Push past the bottom of the page with the wheel: it asks for the
	// continuation exactly like the arrow key does.
	firstAnchor := host.anchor(sessionPickerPageLimit - 1)
	m.sessionPicker.panel.Index = sessionPickerPageLimit - 1
	request := sessionRequest(t, wheelOver(t, &m, 1))
	if request.pickerGeneration != m.sessionPicker.panel.Generation {
		t.Fatal("forward page was not requested under the current generation")
	}
	if after := host.catalogs()[len(host.catalogs())-1].args["after"]; after != firstAnchor {
		t.Fatalf("forward anchor = %v, want the keyset anchor of row 99", after)
	}
	next, _ := m.Update(request)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != sessionPickerPageLimit {
		t.Fatalf("window holds %d rows, want one bounded page", len(m.sessionPicker.panel.Entries))
	}
	if len(m.sessionPicker.stack) != 1 || m.sessionPicker.stack[0] != "" || m.sessionPicker.cursor != firstAnchor {
		t.Fatalf("page history: stack=%v cursor=%q", m.sessionPicker.stack, m.sessionPicker.cursor)
	}
	if m.sessionPicker.panel.Index != 0 {
		t.Fatalf("a forward page starts at its first row, cursor=%d", m.sessionPicker.panel.Index)
	}
	if !m.sessionPicker.panel.More {
		t.Fatal("continuation page did not advertise more rows")
	}

	// One page back: the previous anchor is reused, not refetched from zero.
	cmd := press(t, &m, tea.KeyUp)
	request = sessionRequest(t, cmd)
	if after := host.catalogs()[len(host.catalogs())-1].args["after"]; after != "" {
		t.Fatalf("back anchor = %v, want page 0", after)
	}
	next, _ = m.Update(request)
	m = next.(model)
	if len(m.sessionPicker.stack) != 0 || m.sessionPicker.cursor != "" {
		t.Fatalf("back page history: stack=%v cursor=%q", m.sessionPicker.stack, m.sessionPicker.cursor)
	}
	if m.sessionPicker.panel.Index != sessionPickerPageLimit-1 {
		t.Fatalf("back page should land on the row the user left: %d", m.sessionPicker.panel.Index)
	}

	// Walking forward again reaches the tail page, which has no continuation:
	// pushing down there stops at its last row.
	for want := 1; want <= 2; want++ {
		m.sessionPicker.panel.Index = sessionPickerPageLimit - 1
		next, _ = m.Update(sessionRequest(t, press(t, &m, tea.KeyDown)))
		m = next.(model)
		if m.sessionPicker.cursor != host.anchor(want*sessionPickerPageLimit-1) {
			t.Fatalf("forward page %d landed on anchor %q", want, m.sessionPicker.cursor)
		}
	}
	if m.sessionPicker.next != "" {
		t.Fatalf("tail page advertised a continuation: %q", m.sessionPicker.next)
	}
	if len(m.sessionPicker.panel.Entries) != 50 {
		t.Fatalf("tail page holds %d rows", len(m.sessionPicker.panel.Entries))
	}
	m.sessionPicker.panel.Index = 49
	if cmd := press(t, &m, tea.KeyDown); cmd != nil {
		t.Fatal("the tail page requested a page that does not exist")
	}
	if m.sessionPicker.panel.Index != 49 {
		t.Fatalf("cursor left the tail page: %d", m.sessionPicker.panel.Index)
	}
	if cmd := wheelOver(t, &m, 4); cmd != nil {
		t.Fatal("a wheel burst at the tail requested a page that does not exist")
	}
	if m.sessionPicker.panel.Index != 49 {
		t.Fatalf("a wheel burst left the tail page: %d", m.sessionPicker.panel.Index)
	}

	for _, call := range host.catalogs() {
		if limit, _ := call.args["limit"].(int); limit > sessionPickerPageLimit {
			t.Fatalf("catalog request exceeded the page window: %d", limit)
		}
	}
}

// TestSessionPickerFailureStaysInThePanel pins the error path: a live failure
// is shown by the picker itself, keeps the window open and never becomes a
// transcript notice.
func TestSessionPickerFailureStaysInThePanel(t *testing.T) {
	host := &sessionCatalogHost{total: 2, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	cmd := m.command("/sessions")
	request := sessionRequest(t, cmd)
	request.err = fmt.Errorf("sessions root is not a directory")
	next, _ := m.Update(request)
	m = next.(model)
	if m.sessionPicker.panel.Err == "" || m.sessionPicker.panel.Loading {
		t.Fatalf("live failure was not reported by the picker: %q", m.sessionPicker.panel.Err)
	}
	if m.err != "" {
		t.Fatalf("a picker failure became a global notice: %q", m.err)
	}
	if !m.sessionPicker.open {
		t.Fatal("a page failure dismissed the picker")
	}
	if view := m.View().Content; !strings.Contains(view, "Sessions unavailable") {
		t.Fatalf("failure line is not rendered:\n%s", view)
	}

	// The catalog's own protocol-level refusal takes the same path.
	next, _ = m.Update(m.command("/sessions"))
	m = next.(model)
	next, _ = m.Update(sessionReply(m, `{"error":"cannot list sessions root"}`))
	m = next.(model)
	if !strings.Contains(m.sessionPicker.panel.Err, "cannot list sessions root") {
		t.Fatalf("catalog error was lost: %q", m.sessionPicker.panel.Err)
	}

	// q dismisses the window (Esc is covered by the wheel-routing case).
	press(t, &m, 'q')
	if m.sessionPicker.open {
		t.Fatal("q did not close the picker")
	}
}

// TestSessionPickerWheelPagesAtTheEdge pins the wheel against the same page
// boundaries as the arrow keys: one notch past the last row asks for the
// continuation, and one notch above the first row returns to the page left
// behind — never both, and never a stale generation.
func TestSessionPickerWheelPagesAtTheEdge(t *testing.T) {
	host := &sessionCatalogHost{total: 250, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)
	_, left, top, width, height := m.overlayPanel()
	inside := tea.Mouse{X: left + width/2, Y: top + height/2}

	m.sessionPicker.panel.Index = sessionPickerPageLimit - 1
	next, cmd := m.Update(WheelDeltaMsg{Mouse: inside, DeltaY: 1})
	m = next.(model)
	if cmd == nil {
		t.Fatal("wheel at the bottom edge did not request the next page")
	}
	next, _ = m.Update(sessionRequest(t, cmd))
	m = next.(model)
	if m.sessionPicker.cursor != host.anchor(sessionPickerPageLimit-1) || len(m.sessionPicker.stack) != 1 {
		t.Fatalf("wheel forward: cursor=%q stack=%v", m.sessionPicker.cursor, m.sessionPicker.stack)
	}

	next, cmd = m.Update(WheelDeltaMsg{Mouse: inside, DeltaY: -1})
	m = next.(model)
	if cmd == nil {
		t.Fatal("wheel at the top edge did not request the previous page")
	}
	next, _ = m.Update(sessionRequest(t, cmd))
	m = next.(model)
	if m.sessionPicker.cursor != "" || len(m.sessionPicker.stack) != 0 {
		t.Fatalf("wheel back: cursor=%q stack=%v", m.sessionPicker.cursor, m.sessionPicker.stack)
	}
	if m.sessionPicker.panel.Index != sessionPickerPageLimit-1 {
		t.Fatalf("wheel back did not land on the row left behind: %d", m.sessionPicker.panel.Index)
	}
}

// TestSessionPickerDefersTheCatalogUntilTheAskResolves pins FIFO focus: a
// UiPort ask is the first focus owner, keys stay with the ask, and the page
// that arrives meanwhile installs only after the ask is answered.
func TestSessionPickerDefersTheCatalogUntilTheAskResolves(t *testing.T) {
	host := &sessionCatalogHost{total: 4, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	cmd := m.command("/sessions")
	request := sessionRequest(t, cmd)

	m.applyEvent(event(`{"type":"ui.request","request_id":"u-1","kind":"confirm","prompt":"Approve?"}`))
	if m.modalRequestID != "u-1" || m.sessionPickerFocused() {
		t.Fatal("the ask did not take focus from the picker")
	}
	next, _ := m.Update(request)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 0 || len(m.deferredDialogs) != 1 {
		t.Fatalf("catalog page was not deferred behind the ask: rows=%d deferred=%d", len(m.sessionPicker.panel.Entries), len(m.deferredDialogs))
	}
	// Keys belong to the ask while it is open.
	press(t, &m, tea.KeyDown)
	if m.sessionPicker.panel.Index != 0 {
		t.Fatalf("a key reached the picker behind an ask: picker=%d", m.sessionPicker.panel.Index)
	}
	if m.modalIndex != 1 {
		t.Fatalf("the ask did not consume the key: modalIndex=%d", m.modalIndex)
	}

	next, answer := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = next.(model)
	if answer == nil {
		t.Fatal("answering the ask produced no command")
	}
	for _, result := range pagedResults(answer) {
		next, _ := m.Update(result)
		m = next.(model)
	}
	if m.modalRequestID != "" {
		t.Fatalf("ask did not resolve: %q", m.modalRequestID)
	}
	if len(m.sessionPicker.panel.Entries) != 4 {
		t.Fatalf("deferred page was lost after the ask resolved: %d rows", len(m.sessionPicker.panel.Entries))
	}
	if !m.sessionPickerFocused() {
		t.Fatal("the picker did not regain focus after the ask resolved")
	}
	if !host.sent("ui_response") {
		t.Fatal("the ask was never answered on the wire")
	}
}

// TestSessionPickerChoosesSameFolderWithSwitchSession pins the only resume
// route available today: a row recorded in this workspace reuses
// switch_session, and the picker closes only once that switch succeeds.
func TestSessionPickerChoosesSameFolderWithSwitchSession(t *testing.T) {
	host := &sessionCatalogHost{total: 2, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	m = openTypedSessionPicker(t, &m)
	epoch := m.sessionPickerEpoch

	cmd := press(t, &m, tea.KeyEnter)
	if cmd == nil {
		t.Fatal("enter did not request a switch")
	}
	result, ok := cmd().(commandResult)
	if !ok || result.name != "switch_session" {
		t.Fatalf("same-folder resume did not use switch_session: %#v", result)
	}
	if id := host.requests[len(host.requests)-1].args["id"]; id != host.entry(0).ID {
		t.Fatalf("switch_session id = %v, want %q", id, host.entry(0).ID)
	}
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatal("the picker retired before the switch succeeded")
	}
	// A failed switch must not retire the window.
	failed := commandResult{name: "switch_session", payload: json.RawMessage(`{"error":"session is busy"}`)}
	next, _ := m.Update(failed)
	m = next.(model)
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatalf("a failed switch retired the picker: open=%v epoch=%d", m.sessionPicker.open, m.sessionPickerEpoch)
	}

	m.err = ""
	next, _ = m.Update(commandResult{name: "switch_session", payload: json.RawMessage(`{"session_id":"chosen"}`)})
	m = next.(model)
	if m.sessionPicker.open || m.sessionPickerEpoch <= epoch {
		t.Fatalf("successful switch did not retire the picker: open=%v epoch=%d", m.sessionPicker.open, m.sessionPickerEpoch)
	}
	// The retired picker's replies are refused: nothing paints the closed window.
	late := sessionReply(m, sessionPayload(t, "current", sessionRows(host, 0, 3), nil))
	next, _ = m.Update(late)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 0 || m.err != "" {
		t.Fatalf("a retired picker reply was applied: rows=%d err=%q", len(m.sessionPicker.panel.Entries), m.err)
	}
}

// TestSessionPickerForeignRowsResumeAtomically pins cross-workspace resume:
// a slug-only or vanished-folder row refuses without switching, and a row with
// a live recorded folder sends one atomic switch_session carrying the cwd and
// the inherited permission — never a bare in-workspace switch.
func TestSessionPickerForeignRowsResumeAtomically(t *testing.T) {
	host := &sessionCatalogHost{total: 1, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	cmd := m.command("/sessions")
	sessionRequest(t, cmd)
	m.sessionPicker.panel.Scope = overlays.SessionScopeAll
	foreignCwd := "/workspace/other"
	liveCwd := t.TempDir()
	rows := []overlays.SessionEntry{
		// A slug that spells this workspace's path is still only a label.
		{ID: "slug-only", Bucket: "session_demo_cccccccccccc", Title: "slug only", Folder: "/workspace/demo", SizeBytes: 10},
		{ID: "vanished", Bucket: "session_gone_dddddddddddd", Title: "gone folder", Cwd: &foreignCwd, Folder: "gone", SizeBytes: 20},
		{ID: "foreign", Bucket: "session_other_bbbbbbbbbbbb", Title: "other project", Cwd: &liveCwd, Folder: "other", SizeBytes: 30},
	}
	reply := sessionReply(m, sessionPayload(t, "all", rows, nil))
	reply.pickerScope = overlays.SessionScopeAll
	next, _ := m.Update(reply)
	m = next.(model)
	epoch := m.sessionPickerEpoch

	// The slug is only a label: without a recorded directory this row is never
	// treated as this workspace's, whatever its folder spells.
	m.sessionPicker.panel.Index = 0
	if cmd := press(t, &m, tea.KeyEnter); cmd != nil {
		t.Fatal("a slug-only row requested a resume")
	}
	if !containsAny(m.err, []string{"cannot resume session", "no folder recorded"}) {
		t.Fatalf("slug-only row reported %q", m.err)
	}
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatal("a slug-only row dismissed the picker")
	}

	// A recorded directory that no longer exists refuses without switching.
	m.sessionPicker.panel.Index = 1
	if cmd := press(t, &m, tea.KeyEnter); cmd != nil {
		t.Fatal("a vanished folder requested a resume")
	}
	if !strings.Contains(m.err, "no longer exists") {
		t.Fatalf("vanished folder reported %q", m.err)
	}
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatal("a vanished folder dismissed the picker")
	}
	if host.sent("switch_session") {
		t.Fatal("a foreign row was resumed inside this workspace's catalog")
	}

	// A live recorded folder sends one atomic request carrying the cwd and the
	// inherited permission; the window retires only on its success.
	m.surface.permission = "readonly"
	m.sessionPicker.panel.Index = 2
	switchCmd := press(t, &m, tea.KeyEnter)
	if switchCmd == nil {
		t.Fatal("a live foreign row did not request the atomic resume")
	}
	result, ok := switchCmd().(commandResult)
	if !ok || result.name != "switch_session" {
		t.Fatalf("atomic resume did not use switch_session: %#v", result)
	}
	args := host.requests[len(host.requests)-1].args
	if args["id"] != "foreign" || args["cwd"] != liveCwd || args["permission"] != "readonly" {
		t.Fatalf("atomic resume args = %#v, want id+cwd+inherited permission", args)
	}
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatal("the picker retired before the atomic switch succeeded")
	}
	failed := commandResult{name: "switch_session", payload: json.RawMessage(`{"error":"cannot compose"}`)}
	next, _ = m.Update(failed)
	m = next.(model)
	if !m.sessionPicker.open || m.sessionPickerEpoch != epoch {
		t.Fatal("a failed atomic switch retired the picker")
	}
	next, _ = m.Update(commandResult{name: "switch_session", payload: json.RawMessage(`{"session_id":"foreign"}`)})
	m = next.(model)
	if m.sessionPicker.open || m.sessionPickerEpoch <= epoch {
		t.Fatalf("successful atomic switch did not retire the picker: open=%v epoch=%d", m.sessionPicker.open, m.sessionPickerEpoch)
	}

	// Inside this folder the catalog's own refusal wins, and still no switch.
	// The atomic switch retired the window, so this is a fresh picker.
	fresh := m.command("/sessions")
	if !m.sessionPicker.open {
		t.Fatal("/sessions did not reopen the typed picker")
	}
	sessionRequest(t, fresh)
	corrupt := []overlays.SessionEntry{{
		ID: "corrupt", Bucket: "session_demo_aaaaaaaaaaaa", Title: "corrupt", Folder: "demo",
		Resumable: boolValue(false), Reason: "corrupt session metadata: bad line",
	}}
	current := sessionReply(m, sessionPayload(t, "current", corrupt, nil))
	next, _ = m.Update(current)
	m = next.(model)
	if selected, ok := m.sessionPicker.panel.Selected(); !ok || selected.ID != "corrupt" {
		t.Fatalf("corrupt row was not installed: %#v", m.sessionPicker.panel.Entries)
	}
	if cmd := press(t, &m, tea.KeyEnter); cmd != nil {
		t.Fatal("an explicitly unresumable row requested a switch")
	}
	if !strings.Contains(m.err, "corrupt session metadata") {
		t.Fatalf("the catalog's refusal reason was lost: %q", m.err)
	}
}

// TestSessionPickerWheelRoutingFollowsThePointer pins mouse targeting: a wheel
// over the panel moves the picker cursor, a wheel anywhere else moves nothing at
// all — not even the transcript the panel covers — and with no overlay the
// transcript keeps its one-row-per-notch contract.
func TestSessionPickerWheelRoutingFollowsThePointer(t *testing.T) {
	host := &sessionCatalogHost{total: 10, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	for i := 0; i < 200; i++ {
		m.transcript = append(m.transcript, fmt.Sprintf("row %d", i))
	}
	m.refreshTranscript()
	m.scrollTranscript(-50)
	m = openTypedSessionPicker(t, &m)
	_, left, top, width, height := m.overlayPanel()
	if width == 0 || height == 0 {
		t.Fatal("the picker panel reported no composited geometry")
	}
	before := m.virtualScroll.top

	inside := tea.Mouse{X: left + width/2, Y: top + height/2}
	next, _ := m.Update(WheelDeltaMsg{Mouse: inside, DeltaY: 1})
	m = next.(model)
	if m.sessionPicker.panel.Index != 1 {
		t.Fatalf("wheel over the panel did not move the picker: %d", m.sessionPicker.panel.Index)
	}
	if m.virtualScroll.top != before {
		t.Fatal("wheel over the panel scrolled the covered transcript")
	}

	outside := tea.Mouse{X: 0, Y: max(0, top-1)}
	next, _ = m.Update(WheelDeltaMsg{Mouse: outside, DeltaY: 5})
	m = next.(model)
	if m.sessionPicker.panel.Index != 1 {
		t.Fatalf("wheel outside the panel moved the picker: %d", m.sessionPicker.panel.Index)
	}
	if m.virtualScroll.top != before {
		t.Fatal("wheel outside the panel scrolled the transcript")
	}

	// The raw fallback (embedded adapters without the wheel filter) follows the
	// same pointer routing.
	next, _ = m.Update(tea.MouseWheelMsg{X: inside.X, Y: inside.Y, Button: tea.MouseWheelDown})
	m = next.(model)
	if m.sessionPicker.panel.Index != 2 {
		t.Fatalf("raw wheel over the panel did not move the picker: %d", m.sessionPicker.panel.Index)
	}
	next, _ = m.Update(tea.MouseWheelMsg{X: 0, Y: outside.Y, Button: tea.MouseWheelDown})
	m = next.(model)
	if m.sessionPicker.panel.Index != 2 || m.virtualScroll.top != before {
		t.Fatal("raw wheel outside the panel moved a surface")
	}

	// No overlay: the ordinary transcript still scrolls exactly one row.
	press(t, &m, tea.KeyEsc)
	if m.sessionPicker.open {
		t.Fatal("esc did not close the picker")
	}
	next, _ = m.Update(tea.MouseWheelMsg{X: inside.X, Y: inside.Y, Button: tea.MouseWheelDown})
	m = next.(model)
	if m.virtualScroll.top != before+1 {
		t.Fatalf("ordinary wheel moved %d rows, want 1", m.virtualScroll.top-before)
	}
}

// TestSessionPickerStaleSessionReplyIsRefused pins the session tag: a page
// answered for a session that is no longer attached cannot paint.
func TestSessionPickerStaleSessionReplyIsRefused(t *testing.T) {
	host := &sessionCatalogHost{total: 2, cwd: "/workspace/demo"}
	m := sessionPickerModel(t, host)
	cmd := m.command("/sessions")
	request := sessionRequest(t, cmd)
	request.pickerSession = "retired"
	next, _ := m.Update(request)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 0 {
		t.Fatal("a page for a retired session was installed")
	}
	// Closing retires the window and its epoch.
	press(t, &m, tea.KeyEsc)
	epoch := m.sessionPickerEpoch
	fresh := m.command("/sessions")
	if m.sessionPickerEpoch <= epoch {
		t.Fatal("reopening did not bump the epoch")
	}
	late := request
	late.pickerEpoch = epoch
	next, _ = m.Update(late)
	m = next.(model)
	if len(m.sessionPicker.panel.Entries) != 0 {
		t.Fatal("a reply from the previous picker painted the new one")
	}
	sessionRequest(t, fresh)

	// A runtime redirect changes the attached session: the window that was
	// asked for belongs to the session it left.
	m.applyEvent(event(`{"type":"session.redirect","from":"s-1","to":"s-2"}`))
	if m.sessionPicker.open {
		t.Fatal("a session redirect kept the picker of the previous session")
	}
	if m.sessionPickerEpoch <= epoch {
		t.Fatal("a session redirect did not bump the epoch")
	}
}
