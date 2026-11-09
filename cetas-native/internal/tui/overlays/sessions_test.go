package overlays

// Literals in this file are source-derived: they come from the JavaScript
// oracle (cetas-js/ui/sessions-overlay.ts: formatSize, formatWhen,
// describeSessionEntry, sessionLabel and SessionsPanel.render) and from its
// own fixtures (cetas-js/ui/sessions-overlay.test.ts). They pin the native
// picker to the JS contract; do not re-derive them from the Go implementation.

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/charmbracelet/x/ansi"

	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

// mineBucket is the active project's bucket; foreign rows live elsewhere.
const mineBucket = "session_mine_aaaaaaaaaaaa"

// sessionNow fixes the render clock so the relative timestamps are literals.
var sessionNow = time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)

func cwdValue(s string) *string { return &s }

func at(now time.Time, ago time.Duration) int64 { return now.Add(-ago).UnixMilli() }

// rendered returns the picker's lines with SGR stripped and trailing padding
// trimmed, so a fixture can assert visible text only.
func rendered(p Sessions, width, height int, now time.Time) []string {
	lines := p.Render(ui.Theme{}, width, height, now)
	out := make([]string, len(lines))
	for i, line := range lines {
		out[i] = strings.TrimRight(ansi.Strip(line), " ")
	}
	return out
}

func joined(p Sessions, width, height int, now time.Time) string {
	return strings.Join(rendered(p, width, height, now), "\n")
}

func mineEntry(id string, current bool) SessionEntry {
	return SessionEntry{ID: id, Bucket: mineBucket, ModifiedAt: at(sessionNow, 3*time.Minute), SizeBytes: 2048, Current: current}
}

// TestSessionSizeMatchesJSLiterals pins formatSize to the JS toFixed(1) ladder:
// bytes under 1 KiB (binary), then KB, then MB, one decimal.
func TestSessionSizeMatchesJSLiterals(t *testing.T) {
	for _, tc := range []struct {
		bytes int64
		want  string
	}{
		{0, "0 B"},
		{3, "3 B"},
		{1023, "1023 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{2048, "2.0 KB"},
		// JS renders 1048575 / 1024 = 1023.999… as "1024.0 KB" because the
		// boundary is the 1 MiB test, not the printed value.
		{1048575, "1024.0 KB"},
		{1048576, "1.0 MB"},
		{5767168, "5.5 MB"},
	} {
		if got := formatSize(tc.bytes); got != tc.want {
			t.Fatalf("formatSize(%d) = %q, want %q", tc.bytes, got, tc.want)
		}
	}
}

// TestSessionWhenMatchesJSLiterals pins formatWhen to the JS ladder: minutes,
// hours, days, then the UTC ISO date.
func TestSessionWhenMatchesJSLiterals(t *testing.T) {
	for _, tc := range []struct {
		at   int64
		want string
	}{
		{at(sessionNow, 30*time.Second), "just now"},
		{at(sessionNow, -time.Minute), "just now"}, // a future mtime is not "-1 min ago"
		{at(sessionNow, 5*time.Minute), "5 min ago"},
		{at(sessionNow, 59*time.Minute), "59 min ago"},
		{at(sessionNow, 90*time.Minute), "1 h ago"},
		{at(sessionNow, 23*time.Hour), "23 h ago"},
		{at(sessionNow, 25*time.Hour), "1 d ago"},
		{at(sessionNow, 6*24*time.Hour), "6 d ago"},
		{at(sessionNow, 7*24*time.Hour), "2026-08-23"},
	} {
		if got := formatWhen(tc.at, sessionNow); got != tc.want {
			t.Fatalf("formatWhen(%d) = %q, want %q", tc.at, got, tc.want)
		}
	}
}

// TestSessionLabelMatchesJSLiterals pins sessionLabel: the current-session
// star, the title when present, else the id with its ISO "T" spaced and its
// 8-hex uniqueness suffix dropped (display only).
func TestSessionLabelMatchesJSLiterals(t *testing.T) {
	for _, tc := range []struct {
		entry SessionEntry
		want  string
	}{
		{SessionEntry{ID: "plain-id"}, "  plain-id"},
		{SessionEntry{ID: "plain-id", Current: true}, "* plain-id"},
		{SessionEntry{ID: "2026-08-29T12-17-57-155Z_2c30a4ff"}, "  2026-08-29 12-17-57-155Z"},
		{SessionEntry{ID: "2026-08-29T12-17-57-155Z_2c30a4ff", Title: "Fix the login bug"}, "  Fix the login bug"},
		// Only exactly eight lowercase hex runes after an underscore are the
		// uniqueness suffix.
		{SessionEntry{ID: "cetas-1756fffffff01234"}, "  cetas-1756fffffff01234"},
		{SessionEntry{ID: "session_ABCDEF12"}, "  session_ABCDEF12"},
		{SessionEntry{ID: "run_1234567"}, "  run_1234567"},
	} {
		if got := tc.entry.label(SessionScopeCurrent); got != tc.want {
			t.Fatalf("label(%q) = %q, want %q", tc.entry.ID, got, tc.want)
		}
	}
}

// TestSessionDescribeMatchesJSLiterals pins describeSessionEntry: the All scope
// labels the owning folder name and puts the full path (the value a resume
// uses) in the description; the current-folder scope stays bare.
func TestSessionDescribeMatchesJSLiterals(t *testing.T) {
	p := Sessions{Bucket: mineBucket}
	mine := SessionEntry{ID: "mine", Bucket: mineBucket, ModifiedAt: at(sessionNow, 3*time.Minute), SizeBytes: 2048, Folder: "/work/mine"}
	if label := mine.label(SessionScopeCurrent); strings.Contains(label, "/work/mine") {
		t.Fatalf("current scope labelled the folder path: %q", label)
	}
	if label := mine.label(SessionScopeCurrent); !strings.Contains(label, "mine") {
		t.Fatalf("current scope lost the id label: %q", label)
	}
	if label := mine.label(SessionScopeAll); !strings.Contains(label, "mine  ·  mine") {
		t.Fatalf("All scope label = %q, want the folder name suffix", label)
	}

	theirs := SessionEntry{ID: "theirs", Bucket: "session_theirs_bbbbbbbbbbbb", Title: "title theirs", Folder: "slug", Cwd: cwdValue("/work/theirs")}
	if label := theirs.label(SessionScopeAll); !strings.Contains(label, "theirs") {
		t.Fatalf("All scope label = %q, want the folder name", label)
	}
	if desc := p.description(theirs, SessionScopeAll, sessionNow); !strings.Contains(desc, "/work/theirs") {
		t.Fatalf("All scope description = %q, want the full folder path", desc)
	}
	if desc := p.description(mine, SessionScopeAll, sessionNow); desc != "/work/mine · 3 min ago · 2.0 KB" {
		t.Fatalf("description = %q", desc)
	}
	if desc := p.description(mine, SessionScopeCurrent, sessionNow); desc != "3 min ago · 2.0 KB" {
		t.Fatalf("current-scope description = %q", desc)
	}
}

// TestSessionRefusesForeignRowWithoutRecordedFolder mirrors the JS refusal
// hint: a foreign row whose metadata recorded no folder cannot be resumed from
// here, and the wire's explicit `cwd: null` is "not recorded", never "null".
func TestSessionRefusesForeignRowWithoutRecordedFolder(t *testing.T) {
	var wire SessionEntry
	if err := json.Unmarshal([]byte(`{"id":"legacy","bucket":"session_old_cccccccccccc","folder":"old-project","cwd":null,"sizeBytes":5,"modifiedAt":1000,"current":false}`), &wire); err != nil {
		t.Fatal(err)
	}
	if wire.Cwd != nil {
		t.Fatalf("cwd:null unmarshalled to %q, want nil", *wire.Cwd)
	}
	p := Sessions{Bucket: mineBucket, Entries: []SessionEntry{wire}}
	if p.Resumable(wire) {
		t.Fatal("a foreign row with no recorded folder must not be resumable")
	}
	p.Scope = SessionScopeAll
	got := joined(p, 200, 6, sessionNow)
	if !strings.Contains(got, "no folder recorded — cannot resume from here") {
		t.Fatalf("missing refusal hint:\n%s", got)
	}
	if !strings.Contains(got, "old-project") {
		t.Fatalf("label lost the bucket slug:\n%s", got)
	}
	if strings.Contains(got, "null") {
		t.Fatalf("the wire's null leaked into the row:\n%s", got)
	}
	// The wire's own decision wins when it is present.
	no := false
	pinned := SessionEntry{ID: "pinned", Bucket: mineBucket, Resumable: &no, Reason: "transcript is mid-write"}
	if p.Resumable(pinned) {
		t.Fatal("the wire's resumable:false must win over the bucket default")
	}
	if desc := p.description(pinned, SessionScopeCurrent, sessionNow); !strings.Contains(desc, "transcript is mid-write") {
		t.Fatalf("the wire's reason was not shown: %q", desc)
	}
	// A same-bucket row is always resumable, and a foreign row that recorded
	// its cwd can be resumed by switching folders.
	other := SessionEntry{ID: "other", Bucket: "session_other_bbbbbbbbbbbb", Cwd: cwdValue("/work/other")}
	if !p.Resumable(mineEntry("mine", true)) || !p.Resumable(other) {
		t.Fatal("resumable rows were refused")
	}
}

// TestSessionTitleAndScopeKeys covers the `tab folder scope` toggle and the
// `Current Folder | All` tabs.
func TestSessionTitleAndScopeKeys(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	if !p.Loading || p.Generation != 1 {
		t.Fatalf("a new picker must ask for its first page: loading=%v gen=%d", p.Loading, p.Generation)
	}
	if title := ansi.Strip(p.Title(ui.Theme{})); !strings.Contains(title, "Sessions") || !strings.Contains(title, "[Current Folder]") || !strings.Contains(title, "All") {
		t.Fatalf("title = %q", title)
	}
	if !p.SetEntries(1, []SessionEntry{mineEntry("mine", true)}, false) {
		t.Fatal("the first page was refused")
	}
	toggle := p.Key("tab")
	if toggle.Kind != SessionsLoad || toggle.Scope != SessionScopeAll || toggle.Generation != 2 {
		t.Fatalf("tab must request the All page: %#v", toggle)
	}
	if !p.Loading || p.Err != "" {
		t.Fatal("a scope page request must enter the loading state")
	}
	if title := ansi.Strip(p.Title(ui.Theme{})); !strings.Contains(title, "[All]") {
		t.Fatalf("title after tab = %q", title)
	}
	back := p.Key("shift+tab")
	if back.Kind != SessionsLoad || back.Scope != SessionScopeCurrent || back.Generation != 3 {
		t.Fatalf("shift+tab must request the Current Folder page: %#v", back)
	}
	if p.Scope != SessionScopeCurrent {
		t.Fatalf("scope = %q", p.Scope)
	}
	if title := ansi.Strip(p.Title(ui.Theme{})); !strings.Contains(title, "[Current Folder]") {
		t.Fatalf("title after shift+tab = %q", title)
	}
}

// TestSessionScopeFiltersForeignRows: the current scope shows this project's
// bucket only; the All scope mixes folders and labels them.
func TestSessionScopeFiltersForeignRows(t *testing.T) {
	foreign := SessionEntry{ID: "theirs", Bucket: "session_other_bbbbbbbbbbbb", Title: "title theirs", Cwd: cwdValue("/work/theirs"), ModifiedAt: at(sessionNow, time.Minute), SizeBytes: 3}
	p := NewSessions(SessionScopeCurrent, mineBucket)
	p.SetEntries(1, []SessionEntry{mineEntry("mine", true), foreign}, false)

	if rows := p.Visible(); len(rows) != 1 || rows[0].ID != "mine" {
		t.Fatalf("current scope rows = %#v", rows)
	}
	got := joined(p, 160, 6, sessionNow)
	if !strings.Contains(got, "[Current Folder]") || !strings.Contains(got, "mine") || strings.Contains(got, "theirs") {
		t.Fatalf("current scope render:\n%s", got)
	}
	p.Scope = SessionScopeAll
	got = joined(p, 160, 6, sessionNow)
	if !strings.Contains(got, "[All]") || !strings.Contains(got, "theirs") || !strings.Contains(got, "/work/theirs") {
		t.Fatalf("All scope render:\n%s", got)
	}
	// Enter resumes the row the user sees, foreign or not; the parent decides
	// whether the recorded folder makes it resumable.
	p.Key("down")
	if picked := p.Key("enter"); picked.Kind != SessionsChoose || picked.Entry.ID != "theirs" {
		t.Fatalf("enter on the All scope = %#v", picked)
	}
}

// TestSessionEnterChoosesTheVisibleRow: the cursor walks the scope-filtered
// list and enter reports that row.
func TestSessionEnterChoosesTheVisibleRow(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	p.SetEntries(1, []SessionEntry{mineEntry("old", false), mineEntry("new", true)}, false)
	if picked := p.Key("enter"); picked.Kind != SessionsChoose || picked.Entry.ID != "old" {
		t.Fatalf("enter without navigation = %#v", picked)
	}
	if action := p.Key("down"); action.Kind != SessionsHandled {
		t.Fatalf("down must not ask the parent for anything: %#v", action)
	}
	if picked := p.Key("enter"); picked.Kind != SessionsChoose || picked.Entry.ID != "new" {
		t.Fatalf("enter after down = %#v", picked)
	}
	// The cursor saturates at both ends instead of running off the list.
	for range 5 {
		p.Key("down")
	}
	if picked := p.Key("enter"); picked.Entry.ID != "new" {
		t.Fatalf("cursor escaped the list: %#v", picked)
	}
	for range 5 {
		p.Key("up")
	}
	if picked := p.Key("enter"); picked.Entry.ID != "old" {
		t.Fatalf("cursor escaped the list upwards: %#v", picked)
	}
}

// TestSessionDismissKeys: esc and q cancel, and an empty scope dismisses on any
// other key exactly like the JS panel.
func TestSessionDismissKeys(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	p.SetEntries(1, []SessionEntry{mineEntry("mine", true)}, false)
	for _, key := range []string{"esc", "q"} {
		if action := p.Key(key); action.Kind != SessionsCancel {
			t.Fatalf("%q = %#v, want a cancel", key, action)
		}
	}
	empty := NewSessions(SessionScopeCurrent, mineBucket)
	empty.SetEntries(1, nil, false)
	for _, key := range []string{"enter", "up", "down", "x"} {
		if action := empty.Key(key); action.Kind != SessionsCancel {
			t.Fatalf("an empty scope must dismiss on %q: %#v", key, action)
		}
	}
	// tab still works while the scope is empty: it swaps the scope.
	if action := empty.Key("tab"); action.Kind != SessionsLoad {
		t.Fatalf("tab on an empty scope = %#v", action)
	}
	// A pending page is not an empty answer: a stray key must not drop the
	// request the user already made.
	loading := NewSessions(SessionScopeCurrent, mineBucket)
	for _, key := range []string{"enter", "up", "down", "x"} {
		if action := loading.Key(key); action.Kind != SessionsHandled {
			t.Fatalf("a loading scope dismissed on %q: %#v", key, action)
		}
	}
}

// TestSessionWheelIsACoalescedScalar: the parent folds raw wheel events into
// one delta per frame, so the picker takes a scalar, saturates at the ends and
// never dismisses on a wheel notch.
func TestSessionWheelIsACoalescedScalar(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	entries := make([]SessionEntry, 40)
	for i := range entries {
		entries[i] = mineEntry(string(rune('a'+i%26))+string(rune('0'+i/26)), false)
	}
	p.SetEntries(1, entries, false)
	if action := p.Scroll(1); action.Kind != SessionsHandled {
		t.Fatalf("wheel must not ask the parent for anything: %#v", action)
	}
	if got, _ := p.Selected(); got.ID != entries[1].ID {
		t.Fatalf("one notch selected %q", got.ID)
	}
	// A coalesced burst applies as one clamped move, not notch by notch.
	p.Scroll(1000)
	if got, _ := p.Selected(); got.ID != entries[len(entries)-1].ID {
		t.Fatalf("burst selected %q, want the last row", got.ID)
	}
	p.Scroll(-1000)
	if got, _ := p.Selected(); got.ID != entries[0].ID {
		t.Fatalf("reverse burst selected %q, want the first row", got.ID)
	}
	p.Scroll(0)
	if got, _ := p.Selected(); got.ID != entries[0].ID {
		t.Fatalf("a zero delta moved the cursor to %q", got.ID)
	}
	empty := NewSessions(SessionScopeCurrent, mineBucket)
	empty.SetEntries(1, nil, false)
	if action := empty.Scroll(3); action.Kind != SessionsHandled {
		t.Fatalf("a wheel notch on an empty scope must not dismiss: %#v", action)
	}
}

// TestSessionLoadingAndErrorStates covers the three stand-in lines and the
// generation rule that keeps a late reply from painting stale rows.
func TestSessionLoadingAndErrorStates(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	if got := joined(p, 80, 4, sessionNow); !strings.Contains(got, "Loading sessions…") {
		t.Fatalf("no loading line:\n%s", got)
	}
	if !strings.Contains(ansi.Strip(p.Title(ui.Theme{})), "Sessions") {
		t.Fatal("the title must still render while loading")
	}
	if p.SetError(2, "stale reply") {
		t.Fatal("an error for a future generation was accepted")
	}
	if !p.SetError(1, "\x1b[31mcatalog unavailable\x1b[0m") {
		t.Fatal("the current generation's error was refused")
	}
	if p.Loading {
		t.Fatal("an error must end the loading state")
	}
	got := joined(p, 80, 4, sessionNow)
	if !strings.Contains(got, "catalog unavailable") || strings.Contains(got, "\x1b") {
		t.Fatalf("error line = %q", got)
	}
	// A stale page never replaces the rows on screen, and a fresh one clears
	// the error.
	if p.SetEntries(0, []SessionEntry{mineEntry("stale", false)}, false) {
		t.Fatal("a page from generation 0 was accepted on generation 1")
	}
	if rows := p.Visible(); len(rows) != 0 {
		t.Fatalf("stale rows were installed: %#v", rows)
	}
	if !p.SetEntries(1, []SessionEntry{mineEntry("mine", true)}, false) {
		t.Fatal("the current page was refused")
	}
	if p.Err != "" || p.Loading {
		t.Fatalf("a page must clear the error: err=%q loading=%v", p.Err, p.Loading)
	}
	// A pending page keeps the cached rows on screen; a failure replaces them,
	// because those rows answer the request the picker no longer stands behind.
	if action := p.Refresh(); action.Kind != SessionsLoad || action.Generation != 2 {
		t.Fatalf("refresh = %#v", action)
	}
	if got := joined(p, 80, 4, sessionNow); !strings.Contains(got, "mine") {
		t.Fatalf("a pending page blanked the list:\n%s", got)
	}
	if !p.SetError(2, "catalog unavailable") {
		t.Fatal("the refresh error was refused")
	}
	if got := joined(p, 80, 4, sessionNow); strings.Contains(got, "mine") || !strings.Contains(got, "catalog unavailable") {
		t.Fatalf("a failure left the cached rows up:\n%s", got)
	}
	// The rows behind the failure line are not on screen, so enter must not
	// resume one of them.
	if action := p.Key("enter"); action.Kind != SessionsCancel {
		t.Fatalf("enter resumed a hidden row: %#v", action)
	}
	// Empty scopes say which scope is empty.
	current := NewSessions(SessionScopeCurrent, mineBucket)
	current.SetEntries(1, nil, false)
	if got := joined(current, 120, 4, sessionNow); !strings.Contains(got, "No sessions found in this project") {
		t.Fatalf("current empty state:\n%s", got)
	}
	all := NewSessions(SessionScopeAll, mineBucket)
	all.SetEntries(1, nil, false)
	if got := joined(all, 120, 4, sessionNow); !strings.Contains(got, "No sessions found in any project") {
		t.Fatalf("All empty state:\n%s", got)
	}
}

// TestSessionWindowKeepsTheCursorVisible bounds the rendered window to the
// available height while the cursor stays on screen.
func TestSessionWindowKeepsTheCursorVisible(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	entries := make([]SessionEntry, 20)
	for i := range entries {
		entries[i] = mineEntry("session-"+strings.Repeat("x", i%3)+string(rune('a'+i)), false)
	}
	p.SetEntries(1, entries, false)
	p.Scroll(19)
	rows := p.Rows(ui.Theme{}, 40, 4, sessionNow)
	if len(rows) != 4 {
		t.Fatalf("window height = %d, want 4", len(rows))
	}
	selected := 0
	for i, row := range rows {
		if strings.HasPrefix(ansi.Strip(row), "→ ") {
			selected++
			if i != len(rows)-1 {
				t.Fatalf("the cursor is off the bottom of the window: %d", i)
			}
		}
	}
	if selected != 1 {
		t.Fatalf("the window shows %d selected rows", selected)
	}
	// A taller window than the list is just the list.
	if got := p.Rows(ui.Theme{}, 40, 80, sessionNow); len(got) != len(entries) {
		t.Fatalf("rows = %d, want %d", len(got), len(entries))
	}
}

// TestSessionRenderStaysBoundedAndSanitised is the narrow/CJK/control guard:
// no line is wider than the terminal, nothing raw reaches the screen and the
// renderer never panics on a silly size.
func TestSessionRenderStaysBoundedAndSanitised(t *testing.T) {
	hostile := []SessionEntry{
		{ID: "2026-08-29T12-17-57-155Z_2c30a4ff", Bucket: mineBucket, Title: "修复登录缺陷的会话 sessions", ModifiedAt: at(sessionNow, 90*time.Minute), SizeBytes: 1536},
		{ID: "wide", Bucket: "session_other_bbbbbbbbbbbb", Title: "\x1b[31mred\x1b[0m\x00\x07 title", Folder: "/非常/长/的项目/目录/other-project", Cwd: cwdValue("/work/\x1b[2Jother"), ModifiedAt: at(sessionNow, 9*24*time.Hour), SizeBytes: 5767168},
	}
	for _, width := range []int{1, 2, 5, 12, 24, 40, 120} {
		for _, height := range []int{1, 2, 3, 6, 20} {
			p := Sessions{Bucket: mineBucket, Scope: SessionScopeAll, Entries: hostile}
			for _, line := range p.Render(ui.Theme{}, width, height, sessionNow) {
				if got := ansi.StringWidth(line); got > width {
					t.Fatalf("width %d height %d: line is %d columns: %q", width, height, got, line)
				}
				if strings.Contains(line, "\x1b[31m") || strings.Contains(line, "\x1b[2J") {
					t.Fatalf("width %d height %d: raw escape reached the line: %q", width, height, line)
				}
				for _, r := range ansi.Strip(line) {
					if unicode.IsControl(r) {
						t.Fatalf("width %d height %d: control rune %U in %q", width, height, r, line)
					}
				}
			}
			if lines := p.Render(ui.Theme{}, width, height, sessionNow); len(lines) > height {
				t.Fatalf("width %d height %d: %d lines", width, height, len(lines))
			}
		}
	}
	// A zero or negative box renders nothing instead of panicking.
	p := NewSessions(SessionScopeCurrent, mineBucket)
	for _, width := range []int{0, -1} {
		if lines := p.Render(ui.Theme{}, width, 4, sessionNow); len(lines) != 0 {
			t.Fatalf("width %d rendered %d lines", width, len(lines))
		}
	}
	if lines := p.Rows(ui.Theme{}, 40, 0, sessionNow); len(lines) != 0 {
		t.Fatalf("zero height rendered %d rows", len(lines))
	}
	// The CJK title survives whole when the width allows it.
	wide := Sessions{Bucket: mineBucket, Entries: []SessionEntry{hostile[0]}}
	if got := joined(wide, 120, 6, sessionNow); !strings.Contains(got, "修复登录缺陷的会话") {
		t.Fatalf("CJK title was lost:\n%s", got)
	}
}

// TestSessionCursorSurvivesAPageReplace: the same id can exist in two buckets,
// so the cursor follows the row the user was on, not the id alone.
func TestSessionCursorSurvivesAPageReplace(t *testing.T) {
	p := NewSessions(SessionScopeAll, mineBucket)
	first := []SessionEntry{mineEntry("a", false), mineEntry("b", true), mineEntry("c", false)}
	p.SetEntries(1, first, false)
	p.Key("down")
	if got, _ := p.Selected(); got.ID != "b" {
		t.Fatalf("cursor = %q", got.ID)
	}
	// A re-fetch of the same scope keeps the cursor on b, now at index 2.
	if !p.SetEntries(1, []SessionEntry{mineEntry("c", false), mineEntry("a", false), mineEntry("b", true)}, false) {
		t.Fatal("the re-fetch was refused")
	}
	if got, _ := p.Selected(); got.ID != "b" {
		t.Fatalf("cursor moved to %q after a page replace", got.ID)
	}
	// A different page clamps the cursor instead of pointing past the list.
	p.Scroll(99)
	p.SetEntries(1, []SessionEntry{mineEntry("z", false)}, false)
	if got, _ := p.Selected(); got.ID != "z" {
		t.Fatalf("clamped cursor = %q", got.ID)
	}
	p.SetEntries(1, nil, false)
	if _, ok := p.Selected(); ok {
		t.Fatal("an empty page must have no selection")
	}
}

// TestSessionPagesAppendButNeverTruncate: append extends the visible list for a
// "more" page, and the buffer bound is enforced by refusing an oversized page
// whole — never by trimming it, which would silently hide the sessions past the
// cut. The page already on screen stays untouched and the refusal is visible.
func TestSessionPagesAppendButNeverTruncate(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	p.SetEntries(1, []SessionEntry{mineEntry("a", false)}, false)
	if !p.SetEntries(1, []SessionEntry{mineEntry("b", false)}, true) {
		t.Fatal("the appended page was refused")
	}
	if rows := p.Visible(); len(rows) != 2 || rows[1].ID != "b" {
		t.Fatalf("append = %#v", rows)
	}
	if !p.SetEntries(1, []SessionEntry{mineEntry("c", false)}, false) {
		t.Fatal("the replacing page was refused")
	}
	if rows := p.Visible(); len(rows) != 1 || rows[0].ID != "c" {
		t.Fatalf("replace = %#v", rows)
	}

	// A page one row over the limit is refused whole: the rows on screen stay,
	// the tail is not dropped, and the refusal says why.
	page := make([]SessionEntry, maxSessionRows+1)
	for i := range page {
		page[i] = mineEntry("row", false)
	}
	if p.SetEntries(1, page, false) {
		t.Fatal("an oversized page was accepted")
	}
	if rows := p.Visible(); len(rows) != 1 || rows[0].ID != "c" {
		t.Fatalf("the refused page damaged the rows on screen: %#v", rows)
	}
	if want := "session page of 2049 rows exceeds the 2048-row picker limit"; p.Err != want {
		t.Fatalf("refusal reason = %q, want %q", p.Err, want)
	}
	if got := joined(p, 120, 4, sessionNow); !strings.Contains(got, "exceeds the 2048-row picker limit") {
		t.Fatalf("the refusal is not visible:\n%s", got)
	}
	// The same rule bounds an append, so the parent cannot accumulate the whole
	// catalog one "more" page at a time.
	if p.SetEntries(1, make([]SessionEntry, maxSessionRows), true) {
		t.Fatal("an appending page past the limit was accepted")
	}
	if rows := p.Visible(); len(rows) != 1 || rows[0].ID != "c" {
		t.Fatalf("the refused append damaged the rows on screen: %#v", rows)
	}

	// Exactly at the limit is accepted, and the accepted page clears the
	// refusal.
	if !p.SetEntries(1, page[:maxSessionRows], false) {
		t.Fatal("a full page at the limit was refused")
	}
	if len(p.Entries) != maxSessionRows || p.Err != "" {
		t.Fatalf("full page = %d rows, err %q", len(p.Entries), p.Err)
	}
	if rows := p.Visible(); rows[len(rows)-1].ID != "row" || len(rows) != maxSessionRows {
		t.Fatalf("the accepted page lost its tail: %d rows", len(rows))
	}
	// Overflowing an already full buffer is refused too, not trimmed.
	if p.SetEntries(1, []SessionEntry{mineEntry("more", false)}, true) {
		t.Fatal("an overflowing append onto a full buffer was accepted")
	}
	if len(p.Entries) != maxSessionRows {
		t.Fatalf("row buffer changed to %d", len(p.Entries))
	}
}

// TestSessionEntryWireShape pins the JSON contract the parent's catalog reply
// uses, including the explicit-null `cwd` the MoonBit catalog writes for legacy
// journals, and keeps the metadata fields the picker renders.
func TestSessionEntryWireShape(t *testing.T) {
	var entry SessionEntry
	raw := `{"id":"2026-08-29T12-17-57-155Z_2c30a4ff","bucket":"session_mine_aaaaaaaaaaaa","title":"Fix the login bug","cwd":"/work/mine","folder":"/work/mine","sizeBytes":1536,"modifiedAt":1756000000000,"current":true,"resumable":false,"reason":"transcript is mid-write"}`
	if err := json.Unmarshal([]byte(raw), &entry); err != nil {
		t.Fatal(err)
	}
	if entry.ID == "" || entry.Bucket == "" || entry.Title == "" || entry.Folder == "" {
		t.Fatalf("identity fields: %#v", entry)
	}
	if entry.Cwd == nil || *entry.Cwd != "/work/mine" {
		t.Fatalf("cwd = %v", entry.Cwd)
	}
	if entry.SizeBytes != 1536 || entry.ModifiedAt != 1756000000000 || !entry.Current {
		t.Fatalf("facts: %#v", entry)
	}
	if entry.Resumable == nil || *entry.Resumable || entry.Reason == "" {
		t.Fatalf("resume decision: %#v", entry)
	}
	encoded, err := json.Marshal(SessionEntry{ID: "x"})
	if err != nil {
		t.Fatal(err)
	}
	// cwd stays on the wire even when unrecorded: null is meaningful there.
	for _, want := range []string{`"id":"x"`, `"cwd":null`, `"sizeBytes":0`, `"modifiedAt":0`, `"current":false`} {
		if !strings.Contains(string(encoded), want) {
			t.Fatalf("marshalled entry %s missing %s", encoded, want)
		}
	}
	for _, absent := range []string{`"title"`, `"resumable"`, `"reason"`} {
		if strings.Contains(string(encoded), absent) {
			t.Fatalf("optional field %s was written: %s", absent, encoded)
		}
	}
}

// TestSessionZeroValueIsSafe: the parent holds the picker before the catalog
// arrives, so every accessor and key must work on a zero value.
func TestSessionZeroValueIsSafe(t *testing.T) {
	var p Sessions
	if rows := p.Visible(); len(rows) != 0 {
		t.Fatalf("zero-value rows: %#v", rows)
	}
	if _, ok := p.Selected(); ok {
		t.Fatal("zero-value selection")
	}
	if got := p.Scope; got.normal() != SessionScopeCurrent {
		t.Fatalf("zero-value scope = %q", got)
	}
	if lines := p.Render(ui.Theme{}, 40, 4, sessionNow); len(lines) == 0 {
		t.Fatal("zero value rendered nothing")
	}
	if action := p.Key("down"); action.Kind != SessionsCancel {
		// A zero-value picker has no rows and no pending page: it reads as an
		// empty scope, which the JS panel dismisses on any key.
		t.Fatalf("zero-value down = %#v, want the empty-scope dismissal", action)
	}
	if action := p.Scroll(1); action.Kind != SessionsHandled {
		t.Fatalf("zero-value scroll = %#v", action)
	}
	if action := p.Key("tab"); action.Kind != SessionsLoad || action.Generation != 1 {
		t.Fatalf("zero-value tab = %#v", action)
	}
	if action := p.Key("down"); action.Kind != SessionsHandled {
		t.Fatalf("a requested page must keep the picker open: %#v", action)
	}
	if !p.SetEntries(1, []SessionEntry{mineEntry("mine", true)}, false) {
		t.Fatal("the zero-value picker refused its first page")
	}
}

// TestSessionFooterAndMoreHint pins the footer text (the JS panel footer) and
// the parent's "another page exists" hint.
func TestSessionFooterAndMoreHint(t *testing.T) {
	p := NewSessions(SessionScopeCurrent, mineBucket)
	p.SetEntries(1, []SessionEntry{mineEntry("mine", true)}, false)
	footer := ansi.Strip(p.Footer(ui.Theme{}))
	if footer != sessionFooter {
		t.Fatalf("footer = %q, want %q", footer, sessionFooter)
	}
	if got := joined(p, 200, 6, sessionNow); !strings.Contains(got, "history stays on disk") {
		t.Fatalf("footer missing from the render:\n%s", got)
	}
	p.More = true
	if footer := ansi.Strip(p.Footer(ui.Theme{})); !strings.Contains(footer, "more") {
		t.Fatalf("missing-page hint = %q", footer)
	}
}
