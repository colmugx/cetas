package components

// This file pins Dashboard to the JavaScript statusbar oracle
// (cetas-js/ui/statusbar-dashboard.ts). Every fixture below was produced by
// rendering that module under bun with chalk.level = 3 (truecolor) for exactly
// the same entries, width and context, then recording
//
//   * `want`: the visible text of each row (ANSI stripped), and
//   * `wantSGR`: the ordered SGR parameters each row applies to visible text
//     (resets dropped, open-but-empty spans ignored), so a row that silently
//     loses its muted divider, branch colour, model emphasis or activity style
//     fails instead of merely matching after ansi.Strip.
//
// The entries travel as JSON so a fixture can distinguish an omitted `color`
// from an explicit `color: ""`, which is a real JS distinction: omission means
// "use the model emphasis", an empty role means "identity".
//
// Intentional divergence: Dashboard strips ANSI before cleaning (the JS clean
// helper replaces CSI bytes with spaces). Raw control sequences never reach
// the output; the fixtures therefore only carry ordinary whitespace.

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/charmbracelet/x/ansi"
)

type dashboardOracleCase struct {
	name    string
	width   int
	ctx     DashboardContext
	entries string
	want    []string
	wantSGR [][]string
}

var dashboardOracle = []dashboardOracleCase{
	{
		name:    "wide/120",
		width:   120,
		ctx:     DashboardContext{Branch: "feature/agent", ActiveAgents: 2, AwaitingReplies: 1},
		entries: `[{"key":"permission","value":"yolo","color":"warning"},{"key":"model","value":"glm-5.3-flash:max"},{"key":"manager","value":"Posoco"},{"key":"ctx","value":"ctx: 30.4K/1.0M · 3%"},{"key":"cache","value":"0%"},{"key":"TIME_LIMIT","value":"98% left"},{"key":"5h","value":"62% left"},{"key":"ttft","value":"7841ms"},{"key":"tps","value":"8000.0/s"},{"key":"avg","value":"8000.0/s"},{"key":"session","value":"2026-10-16T10-1"}]`,
		want: []string{
			" glm-5.3-flash:max · Posoco ⑂ feature/agent · 30.4K/1.0M · 3%",
			" yolo · TIME_LIMIT 98% left · 5h 62% left · 2 agents · 1 awaiting reply · cache 0% · ttft 7841ms · tps 8000.0/s",
			" avg 8000.0/s · session 2026-10-16T10-1",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;160;160;160", "38;2;155;225;161", "38;2;160;160;160"},
			{"38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "narrow/24",
		width:   24,
		ctx:     DashboardContext{Branch: "feature/agent", ActiveAgents: 2, AwaitingReplies: 1},
		entries: `[{"key":"permission","value":"yolo","color":"warning"},{"key":"model","value":"glm-5.3-flash:max"},{"key":"manager","value":"Posoco"},{"key":"ctx","value":"ctx: 30.4K/1.0M · 3%"},{"key":"cache","value":"0%"},{"key":"TIME_LIMIT","value":"98% left"},{"key":"5h","value":"62% left"},{"key":"ttft","value":"7841ms"},{"key":"tps","value":"8000.0/s"},{"key":"avg","value":"8000.0/s"},{"key":"session","value":"2026-10-16T10-1"}]`,
		want: []string{
			" glm-5.3-flash:max · Po…",
			" yolo · 30.4K/1.0M · 3%",
			" TIME_LIMIT 98% left",
			" 5h 62% left",
			" 2 agents · 1 awaiting…",
			" cache 0% · ttft 7841ms",
			" +2 more · /statusbar",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160"},
			{"38;2;255;208;128", "38;2;160;160;160"},
			{"38;2;160;160;160"},
			{"38;2;160;160;160"},
			{"38;2;160;160;160"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "overflow/64",
		width:   64,
		ctx:     DashboardContext{Branch: "feature/agent", ActiveAgents: 2, AwaitingReplies: 1},
		entries: `[{"key":"permission","value":"yolo","color":"warning"},{"key":"model","value":"glm-5.3-flash:max"},{"key":"manager","value":"Posoco"},{"key":"ctx","value":"ctx: 30.4K/1.0M · 3%"},{"key":"cache","value":"0%"},{"key":"TIME_LIMIT","value":"98% left"},{"key":"5h","value":"62% left"},{"key":"ttft","value":"7841ms"},{"key":"tps","value":"8000.0/s"},{"key":"avg","value":"8000.0/s"},{"key":"session","value":"2026-10-16T10-1"}]`,
		want: []string{
			" glm-5.3-flash:max · Posoco ⑂ feature/agent · 30.4K/1.0M · 3%",
			" yolo · TIME_LIMIT 98% left · 5h 62% left",
			" 2 agents · 1 awaiting reply · cache 0% · ttft 7841ms",
			" tps 8000.0/s · avg 8000.0/s · session 2026-10-16T10-1",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;160;160;160", "38;2;155;225;161", "38;2;160;160;160"},
			{"38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "postpone/38",
		width:   38,
		ctx:     DashboardContext{Branch: "feature/demo"},
		entries: `[{"key":"model","value":"gpt-6:high"},{"key":"manager","value":"Posoco"},{"key":"ctx","value":"ctx: 30.4K/1.0M · 3%"},{"key":"cache","value":"0%"}]`,
		want: []string{
			" gpt-6:high · Posoco ⑂ feature/demo",
			" 30.4K/1.0M · 3% · cache 0%",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;160;160;160", "38;2;155;225;161"},
			{"38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "quotaReset/120",
		width:   120,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"GPT-6 Luna:high"},{"key":"manager","value":"Posoco"},{"key":"reset","value":"14:30"},{"key":"5h","value":"62%"},{"key":"7d","value":"78%"},{"key":"ctx","value":"38%"},{"key":"permission","value":"yolo","color":"warning"},{"key":"mcp","value":"3/3 Official MCP","color":"success"},{"key":"cache","value":"0%"}]`,
		want: []string{
			" GPT-6 Luna:high · 3/3 Official MCP · Posoco · 38%",
			" yolo · 5h 62% · 7d 78% · Reset 14:30 · cache 0%",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;117;216;153", "38;2;160;160;160", "38;2;160;160;160"},
			{"38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "noModel/40",
		width:   40,
		ctx:     DashboardContext{},
		entries: `[{"key":"cache","value":"0%"}]`,
		want: []string{
			" No model",
			" cache 0%",
		},
		wantSGR: [][]string{
			{"38;2;160;160;160"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "emptyModel/40",
		width:   40,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"  \n\t "},{"key":"cache","value":"0%"}]`,
		want: []string{
			" No model",
			" cache 0%",
		},
		wantSGR: [][]string{
			{"38;2;160;160;160"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "modelSlot/120",
		width:   120,
		ctx:     DashboardContext{Branch: "main"},
		entries: `[{"key":"model","value":"deepseek-v4.1-flash:high"},{"key":"model_slot","value":"opencode-go/deepseek-v4.1-flash"},{"key":"manager","value":"Posoco"}]`,
		want: []string{
			" opencode-go/deepseek-v4.1-flash:high · Posoco ⑂ main",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;160;160;160", "38;2;155;225;161"},
		},
	},
	{
		name:    "modelSlotOpaque/120",
		width:   120,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"deepseek-v4.1-flash:high"},{"key":"model_slot","value":"model_slot:opencode-go/deepseek-v4.1-flash"}]`,
		want: []string{
			" model_slot:opencode-go/deepseek-v4.1-flash:high",
		},
		wantSGR: [][]string{
			{"1"},
		},
	},
	{
		name:    "modelSlotNoModel/120",
		width:   120,
		ctx:     DashboardContext{},
		entries: `[{"key":"model_slot","value":"openrouter/luna"}]`,
		want: []string{
			" openrouter/luna",
		},
		wantSGR: [][]string{
			{"1"},
		},
	},
	{
		name:    "modelColorEmpty/80",
		width:   80,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"gpt-6:high","color":""},{"key":"cache","value":"0%"}]`,
		want: []string{
			" gpt-6:high",
			" cache 0%",
		},
		wantSGR: [][]string{
			{},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "modelColorOmitted/80",
		width:   80,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"gpt-6:high"},{"key":"cache","value":"0%"}]`,
		want: []string{
			" gpt-6:high",
			" cache 0%",
		},
		wantSGR: [][]string{
			{"1"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "modelColorRole/80",
		width:   80,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"gpt-6:high","color":"accent"},{"key":"cache","value":"0%"}]`,
		want: []string{
			" gpt-6:high",
			" cache 0%",
		},
		wantSGR: [][]string{
			{"38;2;85;205;233"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "otherColorEmpty/80",
		width:   80,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"gpt-6:high"},{"key":"session","value":"abc","color":""},{"key":"cache","value":"0%"}]`,
		want: []string{
			" gpt-6:high",
			" session abc · cache 0%",
		},
		wantSGR: [][]string{
			{"1"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "modelSlotColor/120",
		width:   120,
		ctx:     DashboardContext{},
		entries: `[{"key":"model","value":"deepseek-v4.1-flash:high","color":"success"},{"key":"model_slot","value":"opencode-go/deepseek-v4.1-flash"}]`,
		want: []string{
			" opencode-go/deepseek-v4.1-flash:high",
		},
		wantSGR: [][]string{
			{"38;2;117;216;153"},
		},
	},
	{
		name:    "activityAwaiting/80",
		width:   80,
		ctx:     DashboardContext{AwaitingReplies: 2},
		entries: `[{"key":"model","value":"gpt-6:high"}]`,
		want: []string{
			" gpt-6:high",
			" 0 agents · 2 awaiting reply",
		},
		wantSGR: [][]string{
			{"1"},
			{"38;2;160;160;160"},
		},
	},
	{
		name:    "questions/200",
		width:   200,
		ctx:     DashboardContext{Branch: "feature/agent", ActiveAgents: 2, AwaitingReplies: 1, PendingUserQuestions: 2},
		entries: `[{"key":"permission","value":"yolo","color":"warning"},{"key":"model","value":"glm-5.3-flash:max"},{"key":"manager","value":"Posoco"},{"key":"ctx","value":"ctx: 30.4K/1.0M · 3%"},{"key":"cache","value":"0%"},{"key":"TIME_LIMIT","value":"98% left"},{"key":"5h","value":"62% left"},{"key":"ttft","value":"7841ms"},{"key":"tps","value":"8000.0/s"},{"key":"avg","value":"8000.0/s"},{"key":"session","value":"2026-10-16T10-1"}]`,
		want: []string{
			" glm-5.3-flash:max · Posoco ⑂ feature/agent · 30.4K/1.0M · 3%",
			" yolo · TIME_LIMIT 98% left · 5h 62% left · 2 agents · 1 awaiting reply · ? 2 to answer · cache 0% · ttft 7841ms · tps 8000.0/s · avg 8000.0/s · session 2026-10-16T10-1",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;160;160;160", "38;2;155;225;161", "38;2;160;160;160"},
			{"38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;255;208;128", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
	{
		name:    "emptySegments/80",
		width:   80,
		ctx:     DashboardContext{Branch: "   "},
		entries: `[{"key":"model","value":"gpt-6:high"},{"key":"mcp","value":"   "},{"key":"manager","value":"\t\n"}]`,
		want: []string{
			" gpt-6:high",
		},
		wantSGR: [][]string{
			{"1"},
		},
	},
	{
		name:    "cleanWhitespace/80",
		width:   80,
		ctx:     DashboardContext{Branch: "  feature/a\n b  "},
		entries: `[{"key":"model","value":"  gpt-6:high  "},{"key":"cache","value":"  0%   now\t\nnext  "},{"key":"  odd  key ","value":"  spaced:  v\tal  "}]`,
		want: []string{
			" gpt-6:high ⑂ feature/a b",
			" cache 0% now next · odd key spaced: v al",
		},
		wantSGR: [][]string{
			{"1", "38;2;160;160;160", "38;2;155;225;161"},
			{"38;2;160;160;160", "38;2;160;160;160", "38;2;160;160;160"},
		},
	},
}

var (
	sgrSequence = regexp.MustCompile("\x1b\\[([0-9;]*)m")
	sgrAtStart  = regexp.MustCompile("^\x1b\\[[0-9;]*m")
)

// sgrParams lists the non-reset SGR parameters a row applies to visible text,
// in order. A span that is opened but covers no character (which a truncation
// may leave behind) is ignored, so the comparison is about the styles a reader
// actually sees, not about trailing escape noise.
func sgrParams(line string) []string {
	out, pending := []string{}, []string{}
	for i := 0; i < len(line); {
		if line[i] == 0x1b && i+1 < len(line) && line[i+1] == '[' {
			j := i + 2
			for j < len(line) && (line[j] >= '0' && line[j] <= '9' || line[j] == ';') {
				j++
			}
			if j < len(line) && line[j] == 'm' {
				params := line[i+2 : j]
				switch params {
				case "", "0", "22", "23", "24", "27", "39", "49":
					pending = nil
				default:
					pending = append(pending, params)
				}
				i = j + 1
				continue
			}
		}
		_, size := utf8.DecodeRuneInString(line[i:])
		if size == 0 {
			break
		}
		if len(pending) > 0 {
			out = append(out, pending...)
			pending = nil
		}
		i += size
	}
	return out
}

func TestDashboardMatchesJSStatusbarOracle(t *testing.T) {
	for _, c := range dashboardOracle {
		t.Run(c.name, func(t *testing.T) {
			var entries []DashboardEntry
			if err := json.Unmarshal([]byte(c.entries), &entries); err != nil {
				t.Fatalf("fixture entries: %v", err)
			}
			got := Dashboard(Theme{}, entries, c.width, c.ctx)
			if len(got) != len(c.want) {
				t.Fatalf("rows: %#v\nwant: %#v", got, c.want)
			}
			for i := range got {
				if text := ansi.Strip(got[i]); text != c.want[i] {
					t.Fatalf("row %d text: %q\nwant: %q", i, text, c.want[i])
				}
				if params := sgrParams(got[i]); strings.Join(params, " ") != strings.Join(c.wantSGR[i], " ") {
					t.Fatalf("row %d SGR: %q\nwant: %q\nrow: %q", i, params, c.wantSGR[i], got[i])
				}
			}
		})
	}
}

// Statusbar values are untrusted extension input: control sequences must be
// removed instead of becoming part of the rendered row.
func TestDashboardNeverEmitsInjectedControlSequences(t *testing.T) {
	entries := []DashboardEntry{
		{Key: "model", Value: "gpt\x1b]0;pwned\x07:high"},
		{Key: "cache", Value: "\x1b[2J0%\x1b[31m"},
	}
	lines := Dashboard(Theme{}, entries, 80, DashboardContext{Branch: "main\x1b[31m"})
	plain := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(plain, "gpt") || !strings.Contains(plain, "0%") {
		t.Fatalf("benign text was dropped: %q", plain)
	}
	for _, line := range lines {
		for i := 0; i < len(line); i++ {
			switch b := line[i]; {
			case b == 0x1b:
				if !sgrAtStart.MatchString(line[i:]) {
					t.Fatalf("non-SGR escape reached the row: %q", line)
				}
			case b < 0x20:
				t.Fatalf("control byte %q reached the row: %q", b, line)
			}
		}
	}
}
