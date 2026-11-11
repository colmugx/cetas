// Session picker state for the `/sessions` overlay.
//
// The picker is presentation only. The parent owns the catalog, the runtime and
// the paging: it hands the model one page of transcript *metadata* per scope,
// tagged with a generation, and the model reports what the user asked for — a
// scope page, a session to resume, or a dismissal. No transcript body is ever
// opened here; a row is a name, a folder, a size and a timestamp.
//
// The wire contract and the rendered literals follow the JavaScript overlay
// (cetas-js/ui/sessions-overlay.ts) so the native picker reads the same.
package overlays

import (
	"fmt"
	"strings"
	"time"

	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// maxSessionRows caps the row buffer. The parent pages the catalog instead of
// accumulating it, so a page that would overflow the buffer is *refused*, never
// truncated: a truncated buffer would silently drop every session past the cut.
const maxSessionRows = 2048

// sessionFooter is the JS panel footer, verbatim.
const sessionFooter = "tab folder scope · ↑↓ browse · enter resume · esc close · history stays on disk"

// SessionsScope is which folders the picker browses: the active project's
// bucket only, or every project's.
type SessionsScope string

const (
	SessionScopeCurrent SessionsScope = "current"
	SessionScopeAll     SessionsScope = "all"
)

// normal reads an unset scope as the current folder, the JS default.
func (s SessionsScope) normal() SessionsScope {
	if s == SessionScopeAll {
		return SessionScopeAll
	}
	return SessionScopeCurrent
}

// label is the tab caption for the scope.
func (s SessionsScope) label() string {
	if s.normal() == SessionScopeAll {
		return "All"
	}
	return "Current Folder"
}

// SessionEntry is one picker row: transcript metadata only. The parent fills it
// from the cross-project catalog; nothing here opens or reads a transcript.
type SessionEntry struct {
	// ID is the session id: the transcript filename stem (`.jsonl` removed).
	ID string `json:"id"`
	// Bucket is the bucket directory name holding the transcript
	// (`session_<slug>_<hash>`).
	Bucket string `json:"bucket,omitempty"`
	// Title is the display title: the user-chosen name or a prefix of the first
	// user message. Absent means the label falls back to the id.
	Title string `json:"title,omitempty"`
	// Cwd is the project directory recorded in the session metadata. The wire
	// spells "not recorded" as null, which lands here as nil.
	Cwd *string `json:"cwd"`
	// Folder is the label fallback: the recorded cwd, else the project slug
	// recovered from the bucket directory name.
	Folder string `json:"folder,omitempty"`
	// SizeBytes is the transcript size in bytes.
	SizeBytes int64 `json:"sizeBytes"`
	// ModifiedAt is the transcript mtime in milliseconds since the epoch; ids
	// are timestamp-prefixed, so this tracks conversation time.
	ModifiedAt int64 `json:"modifiedAt"`
	// Current marks the session the application is attached to.
	Current bool `json:"current"`
	// Resumable is the catalog's optional decision. Nil means "derive it" with
	// Sessions.Resumable.
	Resumable *bool `json:"resumable,omitempty"`
	// Reason explains why a row cannot be resumed (optional).
	Reason string `json:"reason,omitempty"`
}

// RecordedFolder is the project directory recorded for the session, if any:
// `cwd` when the metadata recorded one, else the folder slug. It is the value a
// resume actually uses.
func (e SessionEntry) RecordedFolder() (string, bool) {
	if cwd, ok := e.recordedCwd(); ok {
		return cwd, true
	}
	if folder := strings.TrimSpace(e.Folder); folder != "" {
		return folder, true
	}
	return "", false
}

// recordedCwd is RecordedFolder without the slug fallback: only a real metadata
// `cwd` makes a foreign row resumable, because a slug cannot be resumed into.
func (e SessionEntry) recordedCwd() (string, bool) {
	if e.Cwd == nil {
		return "", false
	}
	cwd := strings.TrimSpace(*e.Cwd)
	return cwd, cwd != ""
}

// FolderName is the last path segment of RecordedFolder: what a row label can
// afford to print.
func (e SessionEntry) FolderName() (string, bool) {
	full, ok := e.RecordedFolder()
	if !ok {
		return "", false
	}
	trimmed := strings.TrimRight(full, "/\\")
	cut := strings.LastIndexAny(trimmed, "/\\")
	if cut < 0 {
		return trimmed, trimmed != ""
	}
	return trimmed[cut+1:], trimmed[cut+1:] != ""
}

// label is the row's primary text: the current-session star, the title (or the
// id fallback) and, in the All scope, the owning folder's name. The current
// scope is one project by definition, so it stays bare.
func (e SessionEntry) label(scope SessionsScope) string {
	marker := "  "
	if e.Current {
		marker = "* "
	}
	text := strings.TrimSpace(ui.Clean(e.Title))
	if text == "" {
		text = strings.TrimSpace(ui.Clean(displayID(e.ID)))
	}
	if scope.normal() == SessionScopeAll {
		if name, ok := e.FolderName(); ok {
			text += "  ·  " + strings.TrimSpace(ui.Clean(name))
		}
	}
	return marker + text
}

// displayID spells a timestamp id the way the JS picker does: the ISO "T"
// becomes a space and the 8-hex uniqueness suffix is dropped. Display only —
// the id itself and every resume keep the full value.
func displayID(id string) string {
	label := strings.Replace(id, "T", " ", 1)
	if n := len(label); n >= 9 && label[n-9] == '_' && isLowerHex(label[n-8:]) {
		return label[:n-9]
	}
	return label
}

// isLowerHex reports whether s is a run of lowercase hex digits, the shape of
// the uniqueness suffix.
func isLowerHex(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

// SessionsActionKind is what a key, a wheel notch or a refresh asks the parent
// to do next.
type SessionsActionKind int

const (
	// SessionsHandled is the zero action: the picker consumed the input and the
	// parent has nothing to do.
	SessionsHandled SessionsActionKind = iota
	// SessionsLoad means the parent must fetch the page for Scope at
	// Generation and answer with SetEntries or SetError.
	SessionsLoad
	// SessionsChoose means the user resumed Entry; the parent decides whether
	// it can (see Sessions.Resumable).
	SessionsChoose
	// SessionsCancel means the overlay should close without resuming anything.
	SessionsCancel
)

// SessionsAction is the picker's report to its parent.
type SessionsAction struct {
	Kind SessionsActionKind
	// Entry is the row to resume, for SessionsChoose.
	Entry SessionEntry
	// Scope and Generation name the page to fetch, for SessionsLoad.
	Scope      SessionsScope
	Generation int
}

// Sessions is the `/sessions` picker. The zero value is a current-folder picker
// with no rows: every accessor, key and renderer works before the first page
// arrives.
type Sessions struct {
	// Scope is the folder scope the user is browsing.
	Scope SessionsScope
	// Bucket is the active project's bucket directory. Rows in it belong to the
	// current folder and can always be resumed; a foreign row needs a recorded
	// cwd.
	Bucket string
	// Entries is the page the parent fetched, newest first, already ordered.
	Entries []SessionEntry
	// Index is the cursor inside Visible().
	Index int
	// Loading marks a page request the parent has not answered yet.
	Loading bool
	// Err is the parent-reported failure reason; empty means no failure.
	Err string
	// More is parent-assigned: another page exists beyond the rows shown.
	More bool
	// Generation tags every page request. Refresh and scope changes bump it, so
	// a late reply for an older request is refused by SetEntries/SetError
	// instead of painting stale rows.
	Generation int
}

// NewSessions builds a picker for one scope and asks for its first page.
func NewSessions(scope SessionsScope, bucket string) Sessions {
	p := Sessions{Scope: scope.normal(), Bucket: bucket}
	p.Refresh()
	return p
}

// Visible is the scope-filtered list: the current scope keeps this project's
// bucket only. Cached rows stay on screen while the page for a new scope is in
// flight, so switching scope does not blank the list.
func (p Sessions) Visible() []SessionEntry {
	if p.Scope.normal() == SessionScopeAll {
		return p.Entries
	}
	rows := make([]SessionEntry, 0, len(p.Entries))
	for _, e := range p.Entries {
		if p.inBucket(e) {
			rows = append(rows, e)
		}
	}
	return rows
}

// inBucket reports whether the row lives in the active project's bucket. A row
// — or a picker — without a bucket reads as "same folder", matching the JS
// default that a plain listing is a current-folder listing.
func (p Sessions) inBucket(e SessionEntry) bool {
	return p.Bucket == "" || e.Bucket == "" || e.Bucket == p.Bucket
}

// navigable reports whether there is a list on screen to walk: rows the scope
// shows and no failure line standing in for them.
func (p Sessions) navigable() bool { return p.Err == "" && len(p.Visible()) > 0 }

// cursor clamps Index into the visible rows, so a stale index from a previous
// page never indexes past the list.
func (p Sessions) cursor() int {
	last := len(p.Visible()) - 1
	if last < 0 {
		return 0
	}
	return min(max(0, p.Index), last)
}

// Selected is the row the cursor is on.
func (p Sessions) Selected() (SessionEntry, bool) {
	rows := p.Visible()
	at := p.cursor()
	if at >= len(rows) {
		return SessionEntry{}, false
	}
	return rows[at], true
}

// Resumable reports whether a row can be resumed from here. The wire's own
// `resumable` decision wins; otherwise rows in the active bucket always can be
// (same folder), and a foreign row only when its metadata recorded the
// directory it belongs to — the picker never guesses one from a bucket name.
func (p Sessions) Resumable(e SessionEntry) bool {
	if e.Resumable != nil {
		return *e.Resumable
	}
	if p.inBucket(e) {
		return true
	}
	_, ok := e.recordedCwd()
	return ok
}

// resumeReason is why a row cannot be resumed from here, or "" when it can: the
// wire's reason when it sent one, else the refusal hint the JS row prints.
func (p Sessions) resumeReason(e SessionEntry) string {
	if p.Resumable(e) {
		return ""
	}
	if reason := strings.TrimSpace(ui.Clean(e.Reason)); reason != "" {
		return reason
	}
	return "no folder recorded — cannot resume from here"
}

// Refresh marks the view as loading, drops the failure and bumps the generation,
// then hands the parent the page request. The parent answers with SetEntries or
// SetError under that generation.
func (p *Sessions) Refresh() SessionsAction {
	p.Loading = true
	p.Err = ""
	p.Generation++
	p.Index = p.cursor()
	return SessionsAction{Kind: SessionsLoad, Scope: p.Scope.normal(), Generation: p.Generation}
}

// SetEntries installs the page the parent fetched for generation gen. A stale
// generation is refused (false), so a slow reply for the previous scope cannot
// overwrite newer rows.
//
// appendPage extends the rows already shown with a further page; otherwise the
// page replaces them. A page that would push the buffer past maxSessionRows is
// refused whole — nothing is installed, the page already on screen stays, and
// Err says so, because a partially accepted page would silently hide every
// session past the cut. The parent bounds its pages instead of accumulating the
// whole catalog.
func (p *Sessions) SetEntries(gen int, entries []SessionEntry, appendPage bool) bool {
	if gen != p.Generation {
		return false
	}
	total := len(entries)
	if appendPage {
		total += len(p.Entries)
	}
	if total > maxSessionRows {
		p.Loading = false
		p.Err = fmt.Sprintf("session page of %d rows exceeds the %d-row picker limit", total, maxSessionRows)
		return false
	}
	anchor, hadAnchor := p.Selected()
	page := append([]SessionEntry(nil), entries...)
	if appendPage {
		p.Entries = append(p.Entries, page...)
	} else {
		p.Entries = page
	}
	p.Loading, p.Err = false, ""
	if hadAnchor {
		// The same id can legitimately exist in two projects' buckets, so the
		// cursor follows the row the user saw, not the id alone.
		for i, e := range p.Visible() {
			if e.ID == anchor.ID && e.Bucket == anchor.Bucket {
				p.Index = i
				break
			}
		}
	}
	p.Index = min(max(0, p.Index), max(0, len(p.Visible())-1))
	return true
}

// SetError records why the page could not be fetched, under the same generation
// rule as SetEntries.
func (p *Sessions) SetError(gen int, reason string) bool {
	if gen != p.Generation {
		return false
	}
	p.Loading = false
	p.Err = reason
	return true
}

// Key consumes one key and reports what the parent must do: the scope tabs,
// the arrows, enter, esc/q and the empty-scope dismissal are all handled here.
func (p *Sessions) Key(key string) SessionsAction {
	switch key {
	case "q", "esc":
		return SessionsAction{Kind: SessionsCancel}
	case "tab", "shift+tab":
		if p.Scope.normal() == SessionScopeAll {
			p.Scope = SessionScopeCurrent
		} else {
			p.Scope = SessionScopeAll
		}
		p.Index = 0
		return p.Refresh()
	}
	// Nothing to navigate — an empty scope, or a failure whose message replaced
	// the list — dismisses on any other key, like the JS panel. A scope whose
	// page is still in flight is not empty: dismissing would drop a request the
	// user already asked for.
	if !p.navigable() {
		if p.Loading {
			return SessionsAction{}
		}
		return SessionsAction{Kind: SessionsCancel}
	}
	switch key {
	case "up":
		p.move(-1)
	case "down":
		p.move(1)
	case "enter":
		if entry, ok := p.Selected(); ok {
			return SessionsAction{Kind: SessionsChoose, Entry: entry}
		}
	}
	return SessionsAction{}
}

// Scroll moves the cursor by one coalesced wheel delta (positive = down). The
// parent folds the raw wheel events of a frame into one scalar, so no tea mouse
// message or per-notch coalescer reaches this state; an oversized burst
// saturates at the ends of the list instead of being replayed notch by notch. A
// wheel notch never dismisses the picker.
func (p *Sessions) Scroll(delta int) SessionsAction {
	p.move(delta)
	return SessionsAction{}
}

// move shifts the cursor by delta, clamped to the visible rows.
func (p *Sessions) move(delta int) {
	last := len(p.Visible()) - 1
	if last < 0 {
		p.Index = 0
		return
	}
	p.Index = min(max(0, p.cursor()+delta), last)
}

// Title is the scope tab line: `Current Folder | All`, the active scope
// bracketed and accented.
func (p Sessions) Title(t ui.Theme) string {
	tab := func(label string, active bool) string {
		if active {
			return t.Role("accent", "["+label+"]")
		}
		return t.Role("muted", " "+label+" ")
	}
	return t.Role("brand", "Sessions") + "  " +
		tab(SessionScopeCurrent.label(), p.Scope.normal() == SessionScopeCurrent) +
		t.Role("muted", "|") +
		tab(SessionScopeAll.label(), p.Scope.normal() == SessionScopeAll) +
		t.Role("muted", "  — enter resumes, newest first")
}

// Status is the single line that stands in for the list: the failure, the
// pending page or the scope's empty message. It is empty while rows show, but a
// failure wins over cached rows — they answer a request the picker no longer
// stands behind.
func (p Sessions) Status(t ui.Theme) string {
	switch {
	case p.Err != "":
		return t.Role("error", "Sessions unavailable: "+ui.Clean(p.Err))
	case len(p.Visible()) > 0:
		return ""
	case p.Loading:
		return t.Role("muted", "Loading sessions…")
	case p.Scope.normal() == SessionScopeAll:
		return t.Role("muted", "No sessions found in any project")
	}
	return t.Role("muted", "No sessions found in this project")
}

// Footer is the key legend, plus the parent's hint that another page exists.
func (p Sessions) Footer(t ui.Theme) string {
	text := sessionFooter
	if p.More {
		text += " · ↓ more"
	}
	return t.Role("muted", text)
}

// Rows renders the visible window of entries, bounded to height lines and
// width columns. Each row is `label  description`: the label carries the
// selection arrow and the current-session star, the description the folder,
// mtime, size and any refusal reason.
func (p Sessions) Rows(t ui.Theme, width, height int, now time.Time) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	rows := p.Visible()
	start, end := p.window(len(rows), height)
	out := make([]string, 0, end-start)
	for i := start; i < end; i++ {
		out = append(out, ui.Fit(p.row(t, rows[i], now, i == p.cursor()), width))
	}
	return out
}

// window keeps the cursor visible: the slice of rows to show, bounded by
// height.
func (p Sessions) window(count, height int) (int, int) {
	if count <= 0 || height <= 0 {
		return 0, 0
	}
	limit := min(height, count)
	start := max(0, min(p.cursor(), count-1)-limit/2)
	if start+limit > count {
		start = max(0, count-limit)
	}
	return start, start + limit
}

// row is one entry as a single line, sanitized field by field so no control
// byte from a title, a path or a failure reason can reach the terminal.
func (p Sessions) row(t ui.Theme, e SessionEntry, now time.Time, selected bool) string {
	label := "  " + e.label(p.Scope.normal())
	if selected {
		label = t.Role("accent", "→ "+e.label(p.Scope.normal()))
	}
	desc := p.description(e, p.Scope.normal(), now)
	if desc == "" {
		return label
	}
	return label + "  " + t.Role("muted", desc)
}

// description is the muted fact line: in the All scope the full folder path
// (the value a resume uses), then how old the transcript is, how big, whether
// it is the current one and why it cannot be resumed from here.
func (p Sessions) description(e SessionEntry, scope SessionsScope, now time.Time) string {
	facts := make([]string, 0, 5)
	if scope.normal() == SessionScopeAll {
		if full, ok := e.RecordedFolder(); ok {
			facts = append(facts, strings.TrimSpace(ui.Clean(full)))
		}
	}
	facts = append(facts, formatWhen(e.ModifiedAt, now), formatSize(e.SizeBytes))
	if e.Current {
		facts = append(facts, "current")
	}
	if reason := p.resumeReason(e); reason != "" {
		facts = append(facts, reason)
	}
	return strings.Join(facts, " · ")
}

// Render is the whole panel: the scope tabs, the list window or its stand-in
// line, and the footer, bounded to the box the parent gives it.
func (p Sessions) Render(t ui.Theme, width, height int, now time.Time) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	lines := []string{ui.Fit(p.Title(t), width)}
	// The title and the footer own a line each; the list gets the rest. The
	// body is padded to its full height so the panel's geometry — and the
	// compositor's centring of it — never moves while pages stream in or the
	// scope filter changes the row count.
	if body := height - 2; body > 0 {
		if status := p.Status(t); status != "" {
			lines = append(lines, ui.Fit(status, width))
			body--
		} else {
			lines = append(lines, p.Rows(t, width, body, now)...)
		}
		for len(lines)-1 < body {
			lines = append(lines, ui.Pad("", width))
		}
	}
	lines = append(lines, ui.Fit(p.Footer(t), width))
	return ui.Bound(lines, width, height)
}

// formatWhen is the JS relative-time ladder: minutes, hours, days, then the UTC
// date for anything older than a week.
func formatWhen(milliseconds int64, now time.Time) string {
	date := time.UnixMilli(milliseconds)
	minutes := int(now.Sub(date) / time.Minute)
	switch {
	case minutes < 1:
		return "just now"
	case minutes < 60:
		return fmt.Sprintf("%d min ago", minutes)
	}
	hours := minutes / 60
	if hours < 24 {
		return fmt.Sprintf("%d h ago", hours)
	}
	if days := hours / 24; days < 7 {
		return fmt.Sprintf("%d d ago", days)
	}
	return date.UTC().Format("2006-01-02")
}

// formatSize is the JS binary size ladder: bytes, then KB, then MB, one decimal
// from a kilobyte up.
func formatSize(bytes int64) string {
	switch {
	case bytes < 1024:
		return fmt.Sprintf("%d B", bytes)
	case bytes < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(bytes)/(1024*1024))
}
