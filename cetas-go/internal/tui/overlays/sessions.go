// Session picker state for the `/sessions` overlay.
//
// Presentation only: the parent owns the catalog, the runtime and the paging,
// and the model reports what the user asked for — a scope page, a session to
// resume, or a dismissal. No transcript body is ever opened here; a row is a
// name, a folder, a size and a timestamp. The wire contract and the rendered
// literals follow cetas-js/ui/sessions-overlay.ts.
package overlays

import (
	"fmt"
	"strings"
	"time"

	ui "github.com/colmugx/cetas/cetas-go/internal/tui/components"
)

// A page that would overflow the buffer is refused, never truncated: truncation
// would silently drop every session past the cut.
const maxSessionRows = 2048

// Verbatim from the JS panel.
const sessionFooter = "tab folder scope · ↑↓ browse · enter resume · esc close · history stays on disk"

// SessionsScope is the active project's bucket only, or every project's.
type SessionsScope string

const (
	SessionScopeCurrent SessionsScope = "current"
	SessionScopeAll     SessionsScope = "all"
)

// An unset scope reads as the current folder.
func (s SessionsScope) normal() SessionsScope {
	if s == SessionScopeAll {
		return SessionScopeAll
	}
	return SessionScopeCurrent
}

func (s SessionsScope) label() string {
	if s.normal() == SessionScopeAll {
		return "All"
	}
	return "Current Folder"
}

// SessionEntry is one picker row: transcript metadata only.
type SessionEntry struct {
	// ID is the session id: the transcript filename stem (`.jsonl` removed).
	ID string `json:"id"`
	// Bucket is the bucket directory name holding the transcript
	// (`session_<slug>_<hash>`).
	Bucket string `json:"bucket,omitempty"`
	// Title is the user-chosen name or a prefix of the first user message;
	// absent falls back to the id.
	Title string `json:"title,omitempty"`
	// Cwd is the project directory recorded in the session metadata. The wire
	// spells "not recorded" as null, which lands here as nil.
	Cwd *string `json:"cwd"`
	// Folder is the label fallback: the recorded cwd, else the project slug
	// from the bucket directory name.
	Folder string `json:"folder,omitempty"`
	// SizeBytes is the transcript size in bytes.
	SizeBytes int64 `json:"sizeBytes"`
	// ModifiedAt is the transcript mtime in ms since the epoch; ids are
	// timestamp-prefixed, so this tracks conversation time.
	ModifiedAt int64 `json:"modifiedAt"`
	// Current marks the session the application is attached to.
	Current bool `json:"current"`
	// Resumable is the catalog's optional decision. Nil means "derive it" with
	// Sessions.Resumable.
	Resumable *bool `json:"resumable,omitempty"`
	// Reason explains why a row cannot be resumed.
	Reason string `json:"reason,omitempty"`
}

// RecordedFolder is the directory a resume actually uses: the recorded `cwd`,
// else the folder slug.
func (e SessionEntry) RecordedFolder() (string, bool) {
	if cwd, ok := e.recordedCwd(); ok {
		return cwd, true
	}
	if folder := strings.TrimSpace(e.Folder); folder != "" {
		return folder, true
	}
	return "", false
}

// Only a real metadata `cwd` makes a foreign row resumable: a slug cannot be
// resumed into.
func (e SessionEntry) recordedCwd() (string, bool) {
	if e.Cwd == nil {
		return "", false
	}
	cwd := strings.TrimSpace(*e.Cwd)
	return cwd, cwd != ""
}

// FolderName is the last path segment of RecordedFolder.
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

// In the All scope the owning folder's name is appended; the current scope is
// one project by definition, so it stays bare.
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

// Display only: the id itself and every resume keep the full value.
func displayID(id string) string {
	label := strings.Replace(id, "T", " ", 1)
	if n := len(label); n >= 9 && label[n-9] == '_' && isLowerHex(label[n-8:]) {
		return label[:n-9]
	}
	return label
}

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

type SessionsActionKind int

const (
	// SessionsHandled is the zero action: the parent has nothing to do.
	SessionsHandled SessionsActionKind = iota
	// SessionsLoad means the parent must fetch the page for Scope at
	// Generation and answer with SetEntries or SetError.
	SessionsLoad
	// SessionsChoose means the user resumed Entry; the parent decides whether
	// it can.
	SessionsChoose
	// SessionsCancel closes the overlay without resuming.
	SessionsCancel
)

type SessionsAction struct {
	Kind SessionsActionKind
	// Entry is the row to resume, for SessionsChoose.
	Entry SessionEntry
	// Scope and Generation name the page to fetch, for SessionsLoad.
	Scope      SessionsScope
	Generation int
}

// Sessions is the `/sessions` picker. The zero value is a current-folder picker
// with no rows and stays usable before the first page arrives.
type Sessions struct {
	// Scope is the folder scope being browsed.
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
	// Err is the parent-reported failure reason.
	Err string
	// More is parent-assigned: another page exists beyond the rows shown.
	More bool
	// Generation tags every page request. Refresh and scope changes bump it, so
	// a late reply for an older request is refused by SetEntries/SetError
	// instead of painting stale rows.
	Generation int
}

func NewSessions(scope SessionsScope, bucket string) Sessions {
	p := Sessions{Scope: scope.normal(), Bucket: bucket}
	p.Refresh()
	return p
}

// Cached rows stay on screen while the page for a new scope is in flight, so
// switching scope does not blank the list.
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

// A row — or a picker — without a bucket reads as "same folder".
func (p Sessions) inBucket(e SessionEntry) bool {
	return p.Bucket == "" || e.Bucket == "" || e.Bucket == p.Bucket
}

func (p Sessions) navigable() bool { return p.Err == "" && len(p.Visible()) > 0 }

// A stale index from a previous page never indexes past the list.
func (p Sessions) cursor() int {
	last := len(p.Visible()) - 1
	if last < 0 {
		return 0
	}
	return min(max(0, p.Index), last)
}

func (p Sessions) Selected() (SessionEntry, bool) {
	rows := p.Visible()
	at := p.cursor()
	if at >= len(rows) {
		return SessionEntry{}, false
	}
	return rows[at], true
}

// The wire's own `resumable` decision wins; otherwise a foreign row needs a
// recorded directory — the picker never guesses one from a bucket name.
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

// The wire's reason when it sent one, else the refusal hint.
func (p Sessions) resumeReason(e SessionEntry) string {
	if p.Resumable(e) {
		return ""
	}
	if reason := strings.TrimSpace(ui.Clean(e.Reason)); reason != "" {
		return reason
	}
	return "no folder recorded — cannot resume from here"
}

// A refresh bumps the generation, so the answer must come back through
// SetEntries or SetError under it.
func (p *Sessions) Refresh() SessionsAction {
	p.Loading = true
	p.Err = ""
	p.Generation++
	p.Index = p.cursor()
	return SessionsAction{Kind: SessionsLoad, Scope: p.Scope.normal(), Generation: p.Generation}
}

// A stale generation is refused, so a slow reply for the previous scope cannot
// overwrite newer rows. appendPage extends the rows shown; otherwise the page
// replaces them.
//
// A page past maxSessionRows is refused whole — nothing installed, the rows on
// screen stay, Err says so — because a partially accepted page would silently
// hide every session past the cut.
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
// rule.
func (p *Sessions) SetError(gen int, reason string) bool {
	if gen != p.Generation {
		return false
	}
	p.Loading = false
	p.Err = reason
	return true
}

// The scope tabs, arrows, enter, esc/q and the empty-scope dismissal are all
// handled here.
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
	// An empty scope, or a failure line standing in for the list, dismisses on
	// any other key; but a scope with a page in flight is not empty, and
	// dismissing would drop a request already asked for.
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

// One coalesced wheel delta (positive = down): the parent folds a frame's raw
// wheel events into a single scalar, so no per-notch replay reaches this state.
// An oversized burst saturates at the ends, and a notch never dismisses.
func (p *Sessions) Scroll(delta int) SessionsAction {
	p.move(delta)
	return SessionsAction{}
}

func (p *Sessions) move(delta int) {
	last := len(p.Visible()) - 1
	if last < 0 {
		p.Index = 0
		return
	}
	p.Index = min(max(0, p.cursor()+delta), last)
}

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

// A failure wins over cached rows: they answer a request the picker no longer
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

func (p Sessions) Footer(t ui.Theme) string {
	text := sessionFooter
	if p.More {
		text += " · ↓ more"
	}
	return t.Role("muted", text)
}

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

// Sanitized field by field: no control byte from a title, a path or a failure
// reason can reach the terminal.
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

// In the All scope the full folder path comes first: it is the value a resume
// uses.
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

func (p Sessions) Render(t ui.Theme, width, height int, now time.Time) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	lines := []string{ui.Fit(p.Title(t), width)}
	// Padded to full height so the panel's geometry — and the compositor's
	// centring of it — never moves while pages stream in or rows change count.
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

// Minutes, hours, days, then the UTC date past a week.
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

func formatSize(bytes int64) string {
	switch {
	case bytes < 1024:
		return fmt.Sprintf("%d B", bytes)
	case bytes < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(bytes)/(1024*1024))
}
