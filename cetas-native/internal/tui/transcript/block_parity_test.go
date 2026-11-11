package transcript

// Parity goldens here are SOURCE-DERIVED: rendered by the JavaScript oracle
// (cetas-js/src/tool-renderers/* + registry/specs, transcript/components.ts
// ToolRow/UserMessage, transcript/thinking.ts) from the same fixtures with
// FORCE_COLOR=0, ansi-stripped and with the zero-width OSC 133 prompt marks
// removed. They pin the native port to the JS literals; do not re-derive them
// from the Go implementation.
//
// Two JS details the fixtures encode: every JS block owns a leading Spacer(1)
// that the native parent supplies instead, and pi-tui `Text(..., 1, 0)` indents
// every physical line by one column and wraps at width-2, so a row embedding
// "\n" keeps its literal ragged indentation.

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

var parityNow = time.Date(2024, 3, 4, 5, 6, 7, 0, time.UTC)

type toolParityCase struct {
	id       string
	width    int
	expanded bool
	block    Block
	want     []string
}

type textParityCase struct {
	id    string
	width int
	kind  string
	text  string
	live  bool
	want  []string
}

var toolParity = []toolParityCase{
	{
		id: "read/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "pending", Arguments: json.RawMessage(`{"path":"src/a.ts"}`)},
		want:  []string{" ● read src/a.ts"},
	},
	{
		id: "read/call/nopath", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "running", Arguments: json.RawMessage(`{}`)},
		want:  []string{" ● read (no path)"},
	},
	{
		id: "read/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"src/a.ts"}`), Text: "first line\nsecond line\nthird line"},
		want:  []string{" ● read src/a.ts", "       first line  (+2 lines)"},
	},
	{
		id: "read/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "failed", Arguments: json.RawMessage(`{"path":"src/a.ts"}`), Text: "permission denied"},
		want:  []string{" ● read src/a.ts", "       permission denied"},
	},
	{
		id: "read/call/narrow", width: 24, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "pending", Arguments: json.RawMessage(`{"path":"src/deeply/nested/file.ts"}`)},
		want:  []string{" ● read", " src/deeply/nested/file", " .ts"},
	},
	{
		id: "edit/call/all", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "edit", State: "approved", Arguments: json.RawMessage(`{"path":"a.ts","replace_all":true}`)},
		want:  []string{" ● edit a.ts  (all)"},
	},
	{
		id: "edit/call/single", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "edit", State: "pending", Arguments: json.RawMessage(`{"path":"a.ts"}`)},
		want:  []string{" ● edit a.ts  (single)"},
	},
	{
		id: "edit/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "edit", State: "succeeded", Arguments: json.RawMessage(`{"path":"a.ts","replace_all":false}`), Text: "edited 2 hunks"},
		want:  []string{" ● edit a.ts", "       edited 2 hunks"},
	},
	{
		id: "edit/result/summary", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "edit", State: "succeeded", Arguments: json.RawMessage(`{"path":"a.ts"}`), Text: "one\ntwo\nthree\nfour", Structured: map[string]any{"summary": "edited 1 file"}},
		want:  []string{" ● edit a.ts", "       edited 1 file"},
	},
	{
		id: "write/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "write", State: "pending", Arguments: json.RawMessage(`{"path":"b.ts","content":"hello world"}`)},
		want:  []string{" ● write b.ts  (11 bytes)"},
	},
	{
		id: "write/stream", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "write", State: "streaming", Arguments: json.RawMessage(`{"path":"notes/todo.md","content":"l1\nl2\nl3\nl4\nl5"}`)},
		want:  []string{" ● write notes/todo.md  · 5 lines", "       l3", " l4", " l5"},
	},
	{
		id: "write/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "write", State: "succeeded", Arguments: json.RawMessage(`{"path":"b.ts","content":"hello world"}`), Text: "wrote 11 bytes"},
		want:  []string{" ● write b.ts", "       wrote 11 bytes"},
	},
	{
		id: "write/result/expanded", width: 80, expanded: true,
		block: Block{Kind: "tool", Name: "write", State: "succeeded", Arguments: json.RawMessage(`{"path":"b.ts"}`), Text: "w1\nw2\nw3\nw4"},
		want:  []string{" ● write b.ts", "       w1", "       w2", "       w3", "       w4"},
	},
	{
		id: "glob/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "glob", State: "pending", Arguments: json.RawMessage(`{"pattern":"*.ts","path":"src"}`)},
		want:  []string{" ● glob *.ts  src"},
	},
	{
		id: "glob/call/defaultpath", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "glob", State: "running", Arguments: json.RawMessage(`{"pattern":"*.ts"}`)},
		want:  []string{" ● glob *.ts  ."},
	},
	{
		id: "glob/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "glob", State: "succeeded", Arguments: json.RawMessage(`{"pattern":"*"}`), Text: "Found 5 files:\na.ts\nb.ts\nc.ts\nd.ts\ne.ts\n", Structured: map[string]any{"summary": "5 files", "count": float64(5)}},
		want:  []string{" ● glob *", "       5 files", "       a.ts  b.ts  c.ts (+2 more)"},
	},
	{
		id: "glob/result/header-only", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "glob", State: "succeeded", Arguments: json.RawMessage(`{"pattern":"*.rs"}`), Text: "Found 1 files:\nmain.rs\n"},
		want:  []string{" ● glob *.rs", "       1 file", "       main.rs"},
	},
	{
		id: "grep/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "grep", State: "pending", Arguments: json.RawMessage(`{"pattern":"needle","path":"src"}`)},
		want:  []string{" ● grep needle  src"},
	},
	{
		id: "grep/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "grep", State: "succeeded", Arguments: json.RawMessage(`{"pattern":"needle"}`), Text: "Found 27 matches:\nf.txt:1:needle\nf.txt:2:needle\nf.txt:3:needle\nf.txt:4:needle\nf.txt:5:needle\nf.txt:6:needle\nf.txt:7:needle\nf.txt:8:needle\nf.txt:9:needle\nf.txt:10:needle\nf.txt:11:needle\nf.txt:12:needle\nf.txt:13:needle\nf.txt:14:needle\nf.txt:15:needle\nf.txt:16:needle\nf.txt:17:needle\nf.txt:18:needle\nf.txt:19:needle\nf.txt:20:needle\nf.txt:21:needle\nf.txt:22:needle\nf.txt:23:needle\nf.txt:24:needle\nf.txt:25:needle\nf.txt:26:needle\nf.txt:27:needle\n"},
		want:  []string{" ● grep needle", "       27 matches"},
	},
	{
		id: "grep/result/none", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "grep", State: "succeeded", Arguments: json.RawMessage(`{"pattern":"x"}`), Text: "No matches found for: x"},
		want:  []string{" ● grep x", "       no matches"},
	},
	{
		id: "bash/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "bash", State: "running", Arguments: json.RawMessage(`{"cmd":"go test ./..."}`), Started: parityNow.Add(-3 * time.Second)},
		want:  []string{" ● Ran(bash) $ go test ./...  3s"},
	},
	{
		id: "bash/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "bash", State: "succeeded", Arguments: json.RawMessage(`{"cmd":"go test ./..."}`), Text: "ok  ./...\ncoverage 82%"},
		want:  []string{" ● Ran(bash) $ go test ./...", "       ok  ./..."},
	},
	{
		id: "bash/result/expanded", width: 80, expanded: true,
		block: Block{Kind: "tool", Name: "bash", State: "succeeded", Arguments: json.RawMessage(`{"cmd":"ls"}`), Text: "a\nb\nc\nd"},
		want:  []string{" ● Ran(bash) $ ls", "       a", " b", " c", " d"},
	},
	{
		id: "bash/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "bash", State: "failed", Arguments: json.RawMessage(`{"command":"exit 2"}`), Text: "exit=2\nfailed"},
		want:  []string{" ● Ran(bash) $ exit 2", "       exit=2"},
	},
	{
		id: "powershell/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "powershell", State: "running", Arguments: json.RawMessage(`{"cmd":"Get-ChildItem"}`)},
		want:  []string{" ● Ran(ps1) PS> Get-ChildItem  0s"},
	},
	{
		id: "subagent/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "subagent", State: "pending", Arguments: json.RawMessage(`{"task":"fix the login flake"}`)},
		want:  []string{" ● subagent · fix the login flake"},
	},
	{
		id: "subagent/call/params", width: 120, expanded: false,
		block: Block{Kind: "tool", Name: "subagent", State: "running", Arguments: json.RawMessage(`{"task":"fix the login flake","kind":"coder","model":"zai-coding-plan/glm","effort":"max","background":true,"resume":"sub-7","timeout_ms":300000,"tools":["read","grep"],"skills":["tdd"]}`)},
		want:  []string{" ● subagent · fix the login flake", "   kind coder · model zai-coding-plan/glm(max) · background · resume=sub-7 · timeout 5m · tools 2 · skills 1"},
	},
	{
		id: "subagent/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "subagent", State: "succeeded", Arguments: json.RawMessage(`{"task":"fix the login flake"}`), Text: "child finished: all tests pass"},
		want:  []string{" ● subagent", " child finished: all tests pass"},
	},
	{
		id: "ask/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "ask_question", State: "pending", Arguments: json.RawMessage(`{"question":"Deploy now?"}`)},
		want:  []string{" ● ask Deploy now?  [input]"},
	},
	{
		id: "ask/call/options", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "ask_question", State: "pending", Arguments: json.RawMessage(`{"question":"Pick a database","options":["postgres","sqlite"]}`)},
		want:  []string{" ● ask Pick a database", "       [select] 「postgres」 「sqlite」"},
	},
	{
		id: "ask/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "ask_question", State: "succeeded", Arguments: json.RawMessage(`{"question":"Deploy now?"}`), Text: "yes"},
		want:  []string{" ● ask Deploy now?", "       yes"},
	},
	{
		id: "asks/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "notify_user", State: "pending", Arguments: json.RawMessage(`{"question":"Review the plan?"}`)},
		want:  []string{" ● asks Review the plan?  [input]"},
	},
	{
		id: "answer/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "answer_question", State: "pending", Arguments: json.RawMessage(`{"question_id":"question-1"}`)},
		want:  []string{" ● answer · question-1"},
	},
	{
		id: "answer/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "answer_question", State: "succeeded", Arguments: json.RawMessage(`{"question_id":"question-1","text":"postgres"}`), Text: "answer accepted for question question-1 — the child continues\nquestion: Which database?\nanswer: postgres"},
		want:  []string{" ● answer", "     \"Which database?\" → postgres"},
	},
	{
		id: "plan/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "exit_plan_mode", State: "pending", Arguments: json.RawMessage(`{"name":"auth refactor"}`)},
		want:  []string{" ● plan auth refactor"},
	},
	{
		id: "unknown/call", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "memory_search", State: "pending", Arguments: json.RawMessage(`{"q":"ports"}`)},
		want:  []string{" ● memory_search {\"q\":\"ports\"}"},
	},
	{
		id: "unknown/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "memory_search", State: "succeeded", Arguments: json.RawMessage(`{"q":"ports"}`), Text: "r1\nr2\nr3\nr4"},
		want:  []string{" ● memory_search", " r1", " r2", " r3", " … (+1 lines)"},
	},
	{
		id: "unknown/result/expanded", width: 80, expanded: true,
		block: Block{Kind: "tool", Name: "memory_search", State: "succeeded", Arguments: json.RawMessage(`{"q":"ports"}`), Text: "x0\nx1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\nx9\nx10\nx11\nx12\nx13\nx14\nx15\nx16\nx17\nx18\nx19\nx20\nx21\nx22\nx23\nx24\nx25\nx26\nx27\nx28\nx29\nx30\nx31\nx32\nx33\nx34\nx35\nx36\nx37\nx38\nx39\nx40\nx41\nx42\nx43\nx44\nx45\nx46\nx47\nx48\nx49\nx50\nx51\nx52\nx53\nx54\nx55\nx56\nx57\nx58\nx59"},
		want:  []string{" ● memory_search", " x0", " x1", " x2", " x3", " x4", " x5", " x6", " x7", " x8", " x9", " x10", " x11", " x12", " x13", " x14", " x15", " x16", " x17", " x18", " x19", " x20", " x21", " x22", " x23", " x24", " x25", " x26", " x27", " x28", " x29", " x30", " x31", " x32", " x33", " x34", " x35", " x36", " x37", " x38", " x39", " x40", " x41", " x42", " x43", " x44", " x45", " x46", " x47", " x48", " x49", " … (+10 lines)"},
	},
	{
		id: "unknown/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "memory_search", State: "failed", Arguments: json.RawMessage(`{"q":"ports"}`), Text: "boom line1\nboom line2"},
		want:  []string{" ● memory_search", " boom line1", " boom line2"},
	},
	// -- result-view edge bodies and the ask/answer/plan receipts ---------------
	{
		id: "read/result/structured-summary", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"src/a.ts"}`), Text: "first line\nsecond line", Structured: map[string]any{"summary": "read 2 lines"}},
		want:  []string{" ● read src/a.ts", "       first line  (+1 lines)"},
	},
	{
		id: "read/result/empty", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"src/a.ts"}`)},
		want:  []string{" ● read src/a.ts"},
	},
	{
		id: "glob/result/no-header", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "glob", State: "succeeded", Arguments: json.RawMessage(`{"pattern":"*.ts"}`), Text: "a.ts\nb.ts"},
		want:  []string{" ● glob *.ts", "       a.ts b.ts"},
	},
	{
		id: "bash/result/empty", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "bash", State: "succeeded", Arguments: json.RawMessage(`{"cmd":"true"}`)},
		want:  []string{" ● Ran(bash) $ true"},
	},
	{
		id: "bash/call/no-cmd", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "bash", State: "running", Arguments: json.RawMessage(`{}`)},
		want:  []string{" ● Ran(bash) $ (empty)  0s"},
	},
	{
		id: "write/stream/no-content", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "write", State: "streaming", Arguments: json.RawMessage(`{"path":"notes/x.md"}`)},
		want:  []string{" ● write notes/x.md"},
	},
	{
		id: "ask/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "ask_question", State: "failed", Arguments: json.RawMessage(`{"question":"Deploy now?"}`), Text: "question timed out"},
		want:  []string{" ● ask Deploy now?", "       question timed out"},
	},
	{
		id: "asks/result", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "notify_user", State: "succeeded", Arguments: json.RawMessage(`{"question":"Review the plan?"}`), Text: "short_id: @q3\nstatus: pending", Structured: map[string]any{"short_id": "@q3"}},
		want:  []string{" ● asks Review the plan?", "       @q3 submitted · awaiting your answer — /answer @q3 to reply · /questions", " lists all pending"},
	},
	{
		id: "asks/result/content-id", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "notify_user", State: "succeeded", Arguments: json.RawMessage(`{"question":"Review the plan?"}`), Text: "short_id: @q4\nstatus: pending"},
		want:  []string{" ● asks Review the plan?", "       @q4 submitted · awaiting your answer — /answer @q4 to reply · /questions", " lists all pending"},
	},
	{
		id: "asks/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "notify_user", State: "failed", Arguments: json.RawMessage(`{"question":"Review the plan?"}`), Text: "no live session"},
		want:  []string{" ● asks Review the plan?", "       no live session"},
	},
	{
		id: "answer/result/select", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "answer_question", State: "succeeded", Arguments: json.RawMessage(`{"question_id":"question-1","index":0}`), Text: "answer accepted for question question-1 — the child continues", Structured: map[string]any{"question_id": "question-1", "child_session": "sub-1", "answered": true, "question": "Which database should we use?", "type": "select", "options": []any{"postgres", "sqlite"}}},
		want:  []string{" ● answer → sub-1", "     \"Which database should we use?\" → postgres (index 0)"},
	},
	{
		id: "answer/result/confirm", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "answer_question", State: "succeeded", Arguments: json.RawMessage(`{"question_id":"question-2","confirm":true}`), Text: "answer accepted for question question-2 — the child continues", Structured: map[string]any{"question_id": "question-2", "answered": true, "question": "Proceed?", "type": "confirm"}},
		want:  []string{" ● answer", "     \"Proceed?\" → true"},
	},
	{
		id: "answer/result/legacy", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "answer_question", State: "succeeded", Arguments: json.RawMessage(`{"question_id":"question-1","text":"postgres"}`), Text: "answer accepted for question question-1 — the child continues"},
		want:  []string{" ● answer_question", " answer accepted for question question-1 — the child continues"},
	},
	{
		id: "plan/result/collapsed", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "exit_plan_mode", State: "succeeded", Arguments: json.RawMessage(`{"name":"auth refactor"}`), Text: "Plan submitted for user approval — do not make any changes until the user decides:\n\nSaved to .cetas/plan/auth-refactor_s1.md."},
		want:  []string{" ● plan auth refactor", "       Plan submitted for user approval — do not make any changes until the", " user decides:", "       .cetas/plan/auth-refactor_s1.md"},
	},
	{
		id: "plan/result/error", width: 80, expanded: false,
		block: Block{Kind: "tool", Name: "exit_plan_mode", State: "failed", Arguments: json.RawMessage(`{"name":"auth refactor"}`), Text: "Plan returned for revision: add a rollback step"},
		want:  []string{" ● plan auth refactor", "       Plan returned for revision: add a rollback step"},
	},
}

var textParity = []textParityCase{
	{
		// Deliberate deviation: the user block is a framed panel with two-column
		// margins; content wraps at width-4 and every row is exactly `width` cells.
		id: "user/short", width: 40, kind: "user", text: "explain the build", live: false,
		want: []string{
			"                                        ",
			"   explain the build                    ",
			"                                        ",
		},
	},
	{
		id: "user/directive", width: 40, kind: "user", text: "/model", live: false,
		want: []string{
			"                                        ",
			"   /model                               ",
			"                                        ",
		},
	},
	{
		id: "user/chinese", width: 30, kind: "user", text: "把这个目录下的测试全部跑一遍，报告失败原因", live: false,
		want: []string{
			"                              ",
			"   把这个目录下的测试全部跑   ",
			"   一遍，报告失败原因         ",
			"                              ",
		},
	},
	{
		id: "user/multiline", width: 40, kind: "user", text: "first line\nsecond line", live: false,
		want: []string{
			"                                        ",
			"   first line                           ",
			"   second line                          ",
			"                                        ",
		},
	},
	{
		id: "thinking/finalized", width: 80, kind: "thinking", text: "one\ntwo\nthree\nfour\nfive", live: false,
		want: []string{" 💭 thought · 5 lines · ctrl+t 展开", " one", " two", " three", " … (+2 lines)"},
	},
	{
		id: "thinking/live", width: 80, kind: "thinking", text: "one\ntwo\nthree\nfour\nfive", live: true,
		want: []string{" ⠋ thinking...", " three", " four", " five"},
	},
}

func renderCase(c toolParityCase) []string {
	o := Options{Width: c.width, ToolsExpanded: c.expanded, Now: parityNow}
	rendered := c.block.Render(o)
	if rendered == "" {
		return nil
	}
	lines := strings.Split(rendered, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t")
	}
	return lines
}

func TestToolRowsMatchJSOracle(t *testing.T) {
	for _, tc := range toolParity {
		t.Run(tc.id, func(t *testing.T) {
			got := renderCase(tc)
			if strings.Join(got, "\n") != strings.Join(tc.want, "\n") || len(got) != len(tc.want) {
				t.Fatalf("row differs from the JS oracle\n got: %#v\nwant: %#v", got, tc.want)
			}
		})
	}
}

func TestUserAndThinkingBlocksMatchJSOracle(t *testing.T) {
	for _, tc := range textParity {
		t.Run(tc.id, func(t *testing.T) {
			var block Block
			o := Options{Width: tc.width, Now: parityNow}
			if tc.kind == "user" {
				// The bubble keeps its full-width padding, so the golden is compared
				// verbatim, without a right-trim.
				block = Block{Kind: "user", Text: tc.text}
			} else {
				block = Block{Kind: "thinking", Text: tc.text}
				o.ThinkingLive = tc.live
			}
			got := strings.Split(block.Render(o), "\n")
			if tc.kind != "user" {
				for i := range got {
					got[i] = strings.TrimRight(got[i], " \t")
				}
			}
			if strings.Join(got, "\n") != strings.Join(tc.want, "\n") || len(got) != len(tc.want) {
				t.Fatalf("%s block differs from the JS oracle\n got: %#v\nwant: %#v", tc.kind, got, tc.want)
			}
		})
	}
}

// The bullet carries the state colour while the tool title keeps its own style;
// a row whose title inherits the state colour is the bug this pins.
const (
	probePending = "\x1b[33m"
	probeSuccess = "\x1b[32m"
	probeError   = "\x1b[31m"
	probeMuted   = "\x1b[2m"
	probeTitle   = "\x1b[1m"
	probeReset   = "\x1b[m"
)

func probeStyles() Styles {
	wrap := func(open string) func(string) string {
		return func(s string) string { return open + s + probeReset }
	}
	return Styles{
		Muted:     wrap(probeMuted),
		Pending:   wrap(probePending),
		Success:   wrap(probeSuccess),
		Error:     wrap(probeError),
		ToolTitle: wrap(probeTitle),
		Dim:       wrap(probeMuted),
	}
}

func TestToolBulletsAreStateColouredAndTitlesAreNot(t *testing.T) {
	styles := probeStyles()
	args := json.RawMessage(`{"path":"src/a.ts"}`)
	cases := []struct {
		state    string
		bullet   string
		terminal bool
	}{
		{"pending", probePending, false},
		{"running", probePending, false},
		{"approved", probePending, false},
		{"succeeded", probeSuccess, true},
		{"failed", probeError, true},
		{"rejected", probeError, true},
		{"abandoned", probeError, true},
	}
	for _, tc := range cases {
		block := Block{Kind: "tool", Name: "read", State: tc.state, Arguments: args, Text: "one\ntwo"}
		out := block.Render(Options{Width: 80, Styles: styles, Now: parityNow})
		if !strings.Contains(out, tc.bullet+"●"+probeReset) {
			t.Fatalf("%s bullet is not %q: %q", tc.state, tc.bullet, out)
		}
		if !strings.Contains(out, probeTitle+"read"+probeReset) {
			t.Fatalf("%s title lost its own style: %q", tc.state, out)
		}
		for _, wrong := range []string{probeSuccess + "read", probeError + "read", probePending + "read"} {
			if strings.Contains(out, wrong) {
				t.Fatalf("%s title inherited the state colour %q: %q", tc.state, wrong, out)
			}
		}
		// A result view's summary is muted; a call view has no body yet.
		if tc.terminal && !strings.Contains(out, probeMuted) {
			t.Fatalf("%s row has no muted summary: %q", tc.state, out)
		}
	}
}

func TestTerminalToolRowNeverRendersTheCallView(t *testing.T) {
	args := json.RawMessage(`{"cmd":"go test ./..."}`)
	for _, state := range []string{"succeeded", "failed", "rejected", "abandoned"} {
		for _, text := range []string{"", "ok"} {
			block := Block{Kind: "tool", Name: "bash", State: state, Arguments: args, Text: text, Started: parityNow.Add(-3 * time.Second)}
			out := block.Render(Options{Width: 80, Now: parityNow})
			if strings.Contains(out, "3s") || strings.Contains(out, "  0s") {
				t.Fatalf("%s row revived the running elapsed label: %q", state, out)
			}
			if !strings.HasPrefix(out, " ● Ran(bash) $ go test ./...") {
				t.Fatalf("%s row lost its result head line: %q", state, out)
			}
		}
	}
}

// ctrl+o shows up to 50 result lines and counts the remainder: the one deliberate
// divergence from the JS read spec, which keeps its one-line summary even when
// expanded.
func TestExpandedToolRowShowsBodyUpTo50Lines(t *testing.T) {
	var lines []string
	for i := 0; i < 60; i++ {
		lines = append(lines, "l"+strconv.Itoa(i))
	}
	block := Block{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"big.txt"}`), Text: strings.Join(lines, "\n")}
	collapsed := block.Render(Options{Width: 80, Now: parityNow})
	if !strings.Contains(collapsed, "l0  (+59 lines)") || strings.Contains(collapsed, "l3") {
		t.Fatalf("collapsed read row is not the one-line summary: %q", collapsed)
	}
	expanded := strings.Split(block.Render(Options{Width: 80, ToolsExpanded: true, Now: parityNow}), "\n")
	if len(expanded) != 52 {
		t.Fatalf("expanded read row has %d lines, want 52", len(expanded))
	}
	if !strings.Contains(expanded[len(expanded)-2], "l49") || !strings.Contains(expanded[len(expanded)-1], "… (+10 lines)") {
		t.Fatalf("expanded read row is not capped at 50 lines: %#v", expanded[len(expanded)-2:])
	}
	if strings.Contains(strings.Join(expanded, "\n"), "l50") {
		t.Fatal("expanded read row leaked past the 50-line cap")
	}
}

// The user bubble is a full-width surface: the background covers every padded
// cell.
func TestUserBlockIsAFullWidthPaddedSurface(t *testing.T) {
	const width = 40
	block := Block{Kind: "user", Text: "explain the build"}
	plain := block.Render(Options{Width: width})
	lines := strings.Split(plain, "\n")
	if len(lines) != 3 {
		t.Fatalf("user panel lost its frame: %#v", lines)
	}
	if !strings.HasPrefix(lines[1], "   explain the build") {
		t.Fatalf("user block lost its prompt prefix: %#v", lines)
	}
	for _, line := range lines {
		if got := ansi.StringWidth(line); got != width {
			t.Fatalf("user line width = %d, want %d: %q", got, width, line)
		}
	}

	var styled []string
	surface := func(s string) string {
		styled = append(styled, s)
		return "\x1b[48;5;236m" + s + probeReset
	}
	out := block.Render(Options{Width: width, Styles: Styles{User: surface}})
	if len(styled) != 3 {
		t.Fatalf("user surface styled %d fragments, want 3 (frame + content + frame)", len(styled))
	}
	if ansi.StringWidth(styled[0]) != width {
		t.Fatalf("surface covered %d cells, want %d", ansi.StringWidth(styled[0]), width)
	}
	if !strings.HasSuffix(out, probeReset) {
		t.Fatalf("user surface is not closed: %q", out)
	}
}

// With no OSC 10/11 reply the theme degrades to plain text: no colour guessing,
// no stray escapes.
func TestUserBlockStaysSafeWithoutTerminalColours(t *testing.T) {
	block := Block{Kind: "user", Text: "把这个目录下的测试全部跑一遍，报告失败原因"}
	out := block.Render(Options{Width: 24})
	if strings.Contains(out, "\x1b") {
		t.Fatalf("unknown terminal colours emitted escapes: %q", out)
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 4 || strings.TrimSpace(lines[1]) == "" {
		t.Fatalf("narrow user block lost its structure: %#v", lines)
	}
	for _, line := range lines {
		if ansi.StringWidth(line) > 24 {
			t.Fatalf("narrow user line overflows the terminal: %q", line)
		}
	}
}

// Styling is invisible to layout: ANSI never counts as cells and never splits at
// a wrap.
func TestStylesNeverChangeLayout(t *testing.T) {
	styled := probeStyles()
	long := strings.Repeat("wide-token-without-breaks ", 6)
	blocks := []Block{
		{Kind: "user", Text: "explain the build " + long},
		{Kind: "thinking", Text: "one\ntwo\nthree\nfour\nfive"},
		{Kind: "tool", Name: "read", State: "succeeded", Arguments: json.RawMessage(`{"path":"src/deeply/nested/file.ts"}`), Text: long},
		{Kind: "tool", Name: "bash", State: "running", Arguments: json.RawMessage(`{"cmd":"` + long + `"}`)},
		{Kind: "tool", Name: "ask_question", State: "succeeded", Arguments: json.RawMessage(`{"question":"Pick one","options":["a","b"]}`), Text: long},
	}
	for _, block := range blocks {
		for width := 12; width <= 72; width += 4 {
			plain := block.Render(Options{Width: width, Now: parityNow})
			fancy := block.Render(Options{Width: width, Styles: styled, Now: parityNow})
			if ansi.Strip(fancy) != plain {
				t.Fatalf("%s/%s w=%d: styling changed the layout\nplain: %q\nfancy: %q",
					block.Kind, block.Name, width, plain, ansi.Strip(fancy))
			}
			for _, line := range strings.Split(fancy, "\n") {
				// A row only exceeds the terminal when one grapheme cannot fit (2
				// cells at width 1).
				if ansi.StringWidth(line) > max(width, 2) {
					t.Fatalf("%s/%s w=%d: line overflows: %q", block.Kind, block.Name, width, line)
				}
			}
		}
	}
}
