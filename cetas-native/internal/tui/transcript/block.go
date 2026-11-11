// Package transcript owns source-backed transcript blocks, independent of cgo.
//
// A block renders the way the JavaScript host renders the same row: the
// layout, indentation, bullets, summaries and expansion rules below are ported
// from cetas-js/src/tool-renderers/* (registry.ts + specs.ts + the hook
// renderers), transcript/components.ts (ToolRow, UserMessage) and
// transcript/thinking.ts, which stay the oracle for this package.
package transcript

import (
	"charm.land/lipgloss/v2"
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

type Attachment struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
	Text      string `json:"text"`
}

type Block struct {
	Attachments         []Attachment
	Finished            time.Time
	Kind                string
	// ImageID > 0 marks an inline-image block whose rows are kitty
	// placeholder text; 0 renders the plain fallback line.
	ImageID             int
	ImageRows           int
	CallID, Name, State string
	Arguments           json.RawMessage
	Text, Reasoning     string
	Structured          map[string]any
	Started             time.Time
}

// Styles renders the semantic roles of a row. Every field is optional: a nil
// function means "no styling", which keeps unknown terminal colours safe
// instead of guessing them. The bullet carries the row state (traffic light)
// while the tool title keeps its own style, mirroring JS statusBullet versus
// theme.toolTitle.
type Styles struct {
	Muted, Pending, Success, Error, User func(string) string
	// Dim renders secondary metadata (JS theme.dim, e.g. elapsed seconds and
	// the ask type hint). Nil falls back to Muted.
	Dim func(string) string
	// ToolTitle renders the tool name inside a row title (JS theme.toolTitle:
	// bold warning). Nil falls back to Pending. It is never the state colour.
	ToolTitle func(string) string
}

type Options struct {
	Width                           int
	ToolsExpanded, ThinkingExpanded bool
	// ThinkingLive renders a streaming reasoning block: braille spinner header
	// plus the trailing three lines (JS ThinkingComponent live mode). The zero
	// value keeps the finalized rendering, so callers that know nothing about
	// live reasoning are unaffected.
	ThinkingLive bool
	// Frame selects the braille spinner frame for ThinkingLive; see
	// ThinkingFrame. It is ignored by the finalized rendering.
	Frame  int
	Styles Styles
	Now    time.Time
}

const (
	// previewLinesCount is the collapsed body of a fallback result row.
	previewLinesCount = 3
	// expandedLines is the ctrl+o cap (JS EXPANDED_MAX): never flood a screen.
	expandedLines = 50
	// previewChars is the collapsed one-line squeeze (JS truncateForPreview).
	previewChars = 200
	// readSummaryChars is the read summary width (JS readSpec truncateLine).
	readSummaryChars = 120
	// subagentTaskChars bounds the collapsed spawn task preview.
	subagentTaskChars = 120
	// subagentTaskExpandedChars bounds the ctrl+o task dump.
	subagentTaskExpandedChars = 2000
	// thinkingLiveLines is the trailing window of a live thinking block, and
	// also the collapsed preview depth of a finalized one.
	thinkingLiveLines = 3
	// zebraDetailLines is the shortest expanded body that earns the zebra
	// gutter; a handful of lines reads fine evenly indented.
	zebraDetailLines = 6
	spinnerInterval  = 80 * time.Millisecond
)

// brailleFrames is the live thinking spinner (JS BRAILLE_FRAMES).
var brailleFrames = [...]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// ThinkingFrame returns the braille spinner frame active at a wall-clock time.
// Callers that already track an animation tick can pass their own index in
// Options.Frame instead.
func ThinkingFrame(at time.Time) int {
	if at.IsZero() {
		return 0
	}
	ms := at.UnixMilli()
	if ms < 0 {
		return 0
	}
	return int(ms/int64(spinnerInterval/time.Millisecond)) % len(brailleFrames)
}

// Render draws the block at the terminal width. The returned string is one
// complete block: the caller owns inter-block spacing and hard wrapping.
func (b Block) Render(o Options) string {
	width := max(1, o.Width)
	switch b.Kind {
	case "thinking":
		return strings.Join(textLines(b.thinkingText(o), width), "\n")
	case "user":
		// JS: Box(1, 0, userMessageBg) { Text("> " + prompt, 0, 0) }.
		// The native parent deepens the box: one blank padded row above and
		// below, padded margins each side, all carrying the user surface
		// background so the block reads as one findable panel. The margin
		// shrinks with the terminal so a row can never overflow its width.
		padX := min(2, max(0, width/4))
		inner := max(2, width-2*padX)
		lines := bubbleLines(clean(b.Text), inner)
		for i, line := range lines {
			if n := inner - lipgloss.Width(line); n > 0 {
				lines[i] = line + strings.Repeat(" ", n)
			}
			lines[i] = strings.Repeat(" ", padX) + lines[i] + strings.Repeat(" ", padX)
		}
		blank := strings.Repeat(" ", width)
		rows := make([]string, 0, len(lines)+2)
		rows = append(rows, blank)
		rows = append(rows, lines...)
		rows = append(rows, blank)
		if o.Styles.User != nil {
			for i, line := range rows {
				rows[i] = o.Styles.User(line)
			}
		}
		return strings.Join(rows, "\n")
	case "tool":
		return strings.Join(textLines(b.toolText(o), width), "\n")
	}
	return b.Text
}

func styled(fn func(string) string, s string) string {
	if fn != nil {
		return fn(s)
	}
	return s
}

func clean(s string) string { return strings.ReplaceAll(ansi.Strip(s), "\r", "") }

func (s Styles) muted(text string) string { return styled(s.Muted, text) }

// dim renders secondary metadata; it degrades to the muted style when the
// caller has no faint style, so no information is lost.
func (s Styles) dim(text string) string {
	if s.Dim != nil {
		return s.Dim(text)
	}
	return styled(s.Muted, text)
}

func (s Styles) title(text string) string {
	if s.ToolTitle != nil {
		return s.ToolTitle(text)
	}
	return styled(s.Pending, text)
}

// bullet renders the traffic-light glyph for a tool state: amber while the
// call is in flight, green when it succeeded, red when it did not.
func (s Styles) bullet(state string) string {
	switch state {
	case "succeeded":
		return styled(s.Success, "●")
	case "failed", "rejected", "abandoned":
		return styled(s.Error, "●")
	}
	return styled(s.Pending, "●")
}

// -- thinking ---------------------------------------------------------------

func (b Block) thinkingText(o Options) string {
	content := b.Text
	if o.ThinkingLive {
		out := styled(o.Styles.Muted, brailleFrames[frameIndex(o.Frame)]+" thinking...")
		if content != "" {
			lines := strings.Split(content, "\n")
			tail := lines[max(0, len(lines)-thinkingLiveLines):]
			out += "\n" + styled(o.Styles.Muted, strings.Join(tail, "\n"))
		}
		return out
	}
	lines := strings.Split(content, "\n")
	hint := "ctrl+t 展开"
	if o.ThinkingExpanded {
		hint = "ctrl+t 收起"
	}
	header := fmt.Sprintf("💭 thought · %d lines · %s", len(lines), hint)
	if content == "" {
		return styled(o.Styles.Muted, header)
	}
	body := content
	if !o.ThinkingExpanded {
		body = previewLines(content, thinkingLiveLines)
	}
	return styled(o.Styles.Muted, header) + "\n" + styled(o.Styles.Muted, body)
}

func frameIndex(frame int) int {
	if frame < 0 {
		return 0
	}
	return frame % len(brailleFrames)
}

// -- tool rows --------------------------------------------------------------

// ToolPhase is the closed behavioral vocabulary for a tool row's lifecycle.
// The wire sends phase strings (console protocol) and the replayed journal
// sends its own historical status words; both normalize here so "is this row
// settled / failed / animating" has exactly one source of truth. A wire value
// outside the known sets is deliberately terminal: an unrecognized phase must
// settle the row instead of animating and mutating forever.
type ToolPhase uint8

const (
	PhaseActive ToolPhase = iota // pending, approved, started, streaming, running
	PhaseSucceeded
	PhaseFailed
	PhaseRejected
	PhaseAbandoned
	PhaseUnknown // outside every known set: terminal, neither success nor failure
)

func ParseToolPhase(state string) ToolPhase {
	switch state {
	case "succeeded", "done", "completed":
		return PhaseSucceeded
	case "failed", "error":
		return PhaseFailed
	case "rejected":
		return PhaseRejected
	case "abandoned":
		return PhaseAbandoned
	case "", "pending", "approved", "started", "running", "streaming":
		return PhaseActive
	default:
		return PhaseUnknown
	}
}

// Terminal reports a settled row: it renders the result view from now on and
// never falls back to the call view, even when the result body is empty.
func (p ToolPhase) Terminal() bool { return p != PhaseActive }

func (p ToolPhase) Failed() bool {
	return p == PhaseFailed || p == PhaseRejected || p == PhaseAbandoned
}

// Label is the canonical state string of a known phase; callers keep the raw
// wire word for PhaseUnknown.
func (p ToolPhase) Label() string {
	switch p {
	case PhaseSucceeded:
		return "succeeded"
	case PhaseFailed:
		return "failed"
	case PhaseRejected:
		return "rejected"
	case PhaseAbandoned:
		return "abandoned"
	default:
		return ""
	}
}

func (b Block) terminal() bool { return ParseToolPhase(b.State).Terminal() }

func (b Block) failed() bool { return ParseToolPhase(b.State).Failed() }

func (b Block) args() map[string]any {
	if len(b.Arguments) == 0 {
		return nil
	}
	var args map[string]any
	if err := json.Unmarshal(b.Arguments, &args); err != nil {
		// Streamed fragments are not valid JSON until the call starts; render
		// what we can rather than dropping the row.
		return nil
	}
	return args
}

func (b Block) toolText(o Options) string {
	args := b.args()
	text := b.callText(o, args)
	if b.terminal() {
		text = b.resultText(o, args)
	}
	for _, attachment := range b.Attachments {
		if attachment.Type == "image" {
			text += "\n   " + o.Styles.muted(fmt.Sprintf("🖼 %s ~%dKB", attachment.MediaType, len(attachment.Data)*3/4/1024))
		}
	}
	return text
}

// callText renders the pre-result view (JS renderCall).
func (b Block) callText(o Options, args map[string]any) string {
	s := o.Styles
	bullet := s.bullet(b.State)
	switch b.Name {
	case "read":
		return bullet + " " + s.title("read") + " " + argText(args, "(no path)", "path")
	case "edit":
		return bullet + " " + s.title("edit") + " " + argText(args, "(no path)", "path") + "  " + s.muted(editMode(args))
	case "write":
		head := bullet + " " + s.title("write")
		path := argString(args, "path")
		content := argString(args, "content")
		if b.State == "streaming" {
			// JS write.ts live-args view: content arrives in fragments, so show
			// the line count and the last three lines while it streams.
			if path != "" {
				head += " " + clean(path)
			} else {
				head += " …"
			}
			if content != "" {
				tail := strings.Split(content, "\n")
				tail = tail[max(0, len(tail)-thinkingLiveLines):]
				return head + "  " + s.muted(fmt.Sprintf("· %d lines", len(strings.Split(content, "\n")))) +
					"\n      " + s.muted(strings.Join(tail, "\n"))
			}
			return head
		}
		head += " " + argText(args, "(no path)", "path")
		if content != "" {
			head += "  " + s.muted(fmt.Sprintf("(%d bytes)", runeLen(content)))
		}
		return head
	case "glob", "grep":
		pattern := argString(args, "pattern")
		if pattern == "" {
			pattern = "(no pattern)"
		} else {
			pattern = styled(s.Pending, clean(pattern))
		}
		return bullet + " " + s.title(b.Name) + " " + pattern + "  " + s.muted(argText(args, ".", "path"))
	case "bash", "powershell", "ps1":
		title, prompt := "Ran(bash)", "$"
		if b.Name != "bash" {
			title, prompt = "Ran(ps1)", "PS>"
		}
		return bullet + " " + s.title(title) + " " + s.muted(prompt) + " " +
			argText(args, "(empty)", "cmd", "command") +
			"  " + s.dim(fmt.Sprintf("%ds", elapsedSeconds(b, o.Now)))
	case "subagent", "zcode":
		parts := []string{s.title("subagent")}
		task := oneLine(argString(args, "task"))
		if task != "" {
			parts = append(parts, s.muted("· "+truncateRunes(task, subagentTaskChars)))
		}
		text := bullet + " " + strings.Join(parts, " ")
		if params := spawnParamsLine(args); params != "" {
			text += "\n  " + s.dim(params)
		}
		if o.ToolsExpanded && runeLen(task) > subagentTaskChars {
			text += "\n  " + s.dim(truncateRunes(task, subagentTaskExpandedChars))
		}
		return text
	case "ask_question":
		return askCallText(s, b.State, args, "ask")
	case "notify_user":
		return askCallText(s, b.State, args, "asks")
	case "answer_question":
		return bullet + " " + s.title("answer") + " " + s.dim("· "+argText(args, "(no question id)", "question_id"))
	case "exit_plan_mode":
		head := bullet + " " + s.title("plan") + " " + argText(args, "(unnamed)", "name")
		// JS renders the plan body as Markdown; the native row keeps the text
		// verbatim because this package has no Markdown renderer.
		if plan := argString(args, "plan"); plan != "" {
			return head + "\n" + clean(plan)
		}
		return head
	}
	// Unknown tools fall back to the JSON argument dump (JS fallback.ts).
	raw := oneLine(string(b.Arguments))
	if raw == "" {
		raw = "{}"
	}
	return bullet + " " + s.title(b.Name) + " " + s.muted(raw)
}

// resultText renders the settled view (JS renderResult): line one is the
// bullet, the tool title and the primary argument; the body is summarized per
// tool and indented by six columns.
func (b Block) resultText(o Options, args map[string]any) string {
	s := o.Styles
	expanded := o.ToolsExpanded
	content := clean(b.Text)
	failed := b.failed()
	switch b.Name {
	case "read":
		primary := argText(args, "(no path)", "path")
		var summary string
		switch {
		case expanded:
			summary = zebraDetail(previewLines(content, expandedLines))
		case failed:
			summary = truncateForPreview(content, previewChars)
		default:
			lines := strings.Split(content, "\n")
			summary = truncateRunes(lines[0], readSummaryChars)
			if len(lines) > 1 {
				summary += "  " + s.muted(fmt.Sprintf("(+%d lines)", len(lines)-1))
			}
		}
		return resultBlock(s, b.State, "read", primary, summary)
	case "edit", "write":
		return resultBlock(s, b.State, b.Name, argText(args, "(no path)", "path"), b.specSummary(content, expanded, failed, nil))
	case "glob":
		return resultBlock(s, b.State, "glob", patternPrimary(s, args), b.specSummary(content, expanded, failed, b.globSummary))
	case "grep":
		return resultBlock(s, b.State, "grep", patternPrimary(s, args), b.specSummary(content, expanded, failed, b.grepSummary))
	case "bash", "powershell", "ps1":
		title, prompt := "Ran(bash)", "$"
		if b.Name != "bash" {
			title, prompt = "Ran(ps1)", "PS>"
		}
		head := s.bullet(b.State) + " " + s.title(title) + " " + s.muted(prompt) + " " + argText(args, "", "cmd", "command")
		body := truncateForPreview(firstLine(content), previewChars)
		if expanded {
			body = zebraDetail(previewLines(content, expandedLines))
		}
		if body == "" {
			return head
		}
		// JS keeps the whole body in one muted Text; the expanded preview is
		// where the native row adds the zebra gutter.
		return head + "\n      " + s.muted(body)
	case "subagent", "zcode":
		return plainResultBlock(s, b.State, "subagent", b.specBody(content, expanded))
	case "ask_question":
		head := s.bullet(b.State) + " " + s.title("ask") + " " + argText(args, "(no question)", "question")
		return head + "\n      " + s.muted(truncateRunes(content, previewChars))
	case "notify_user":
		return b.notifyResult(s, args, content, failed)
	case "answer_question":
		return b.answerResult(o, args, content)
	case "exit_plan_mode":
		return b.planResult(o, args)
	}
	return plainResultBlock(s, b.State, b.Name, b.specBody(content, expanded))
}

func (b Block) notifyResult(s Styles, args map[string]any, content string, failed bool) string {
	head := s.bullet(b.State) + " " + s.title("asks") + " " + argText(args, "(no question)", "question")
	if failed {
		return head + "\n      " + s.muted(truncateRunes(content, previewChars))
	}
	label := ""
	if raw, ok := b.Structured["short_id"].(string); ok && raw != "" {
		label = raw
	}
	if label == "" {
		label = contentValue(content, "short_id")
	}
	target, note := " /answer", ""
	if label != "" {
		target, note = " /answer "+label, label+" "
	}
	note += "submitted · awaiting your answer —" + target + " to reply · /questions lists all pending"
	return head + "\n      " + s.muted(note)
}

// answerResult is the durable record of the parent agent's reply. A live
// receipt answers with the parked question and the submitted word (derived from
// the call args, exactly like JS answer.ts answerWord); a replay receipt
// rebuilds the pair from its `question:`/`answer:` lines. Legacy or failed
// receipts delegate to the fallback renderer, whose title is the wire name.
func (b Block) answerResult(o Options, args map[string]any, content string) string {
	s := o.Styles
	if !b.failed() {
		if question, answer, child, ok := b.answeredPair(args, content); ok {
			head := s.bullet(b.State) + " " + s.title("answer")
			if child != "" {
				head += " → " + s.muted(clean(child))
			}
			if question == "" {
				return head + "\n    " + s.muted(answer)
			}
			return head + "\n    " + `"` + question + `" → ` + s.muted(answer)
		}
	}
	return plainResultBlock(s, b.State, b.Name, b.specBody(content, o.ToolsExpanded))
}

func (b Block) planResult(o Options, args map[string]any) string {
	s := o.Styles
	head := s.bullet(b.State) + " " + s.title("plan") + " " + argText(args, "(unnamed)", "name")
	content := clean(b.Text)
	var details []string
	if first := strings.TrimSpace(firstLine(content)); first != "" {
		details = append(details, s.muted(truncateForPreview(first, 160)))
	}
	if saved := savedPlanPath(content); saved != "" {
		details = append(details, s.muted(saved))
	}
	plan := clean(argString(args, "plan"))
	if plan == "" {
		if len(details) == 0 {
			return head
		}
		return head + "\n      " + strings.Join(details, "\n      ")
	}
	if o.ToolsExpanded {
		// JS re-renders the approved plan body behind ctrl+o; the native row
		// keeps the text verbatim.
		body := head
		if len(details) > 0 {
			body += "\n      " + strings.Join(details, "\n      ")
		}
		return body + "\n" + plan
	}
	details = append(details, s.muted("ctrl+o plan"))
	return head + "\n      " + strings.Join(details, "\n      ")
}

// specSummary is the JS result body chain: tool-specific summarize →
// structured.summary → truncated content. Errors always show their content,
// and ctrl+o widens any of them to the 50-line cap.
func (b Block) specSummary(content string, expanded, failed bool, summarize func(string) string) string {
	if expanded {
		return zebraDetail(previewLines(content, expandedLines))
	}
	if failed {
		return truncateForPreview(content, previewChars)
	}
	if summarize != nil {
		if summary := summarize(content); summary != "" {
			return summary
		}
	}
	if summary := summaryOf(b.Structured); summary != "" {
		return summary
	}
	return truncateForPreview(content, previewChars)
}

// zebraDetail steps every other line of a long expanded body out by one column.
// Over dozens of argument or result lines the alternating gutter is what keeps
// the eye on a single row; short bodies keep the even indent (a gutter over
// three lines is noise), and the collapsed view never reaches here. Rendering
// only: the block's raw text, which the copy path reads, is untouched.
func zebraDetail(body string) string {
	lines := strings.Split(body, "\n")
	if len(lines) < zebraDetailLines {
		return body
	}
	for i := 1; i < len(lines); i += 2 {
		lines[i] = " " + lines[i]
	}
	return strings.Join(lines, "\n")
}

// specBody is the fallback result body: the structured summary wins over the
// content preview (JS fallback.ts).
func (b Block) specBody(content string, expanded bool) string {
	if summary := summaryOf(b.Structured); summary != "" {
		return summary
	}
	limit := previewLinesCount
	if expanded {
		limit = expandedLines
	}
	return previewLines(content, limit)
}

func (b Block) globSummary(content string) string {
	summary := summaryOf(b.Structured)
	if summary == "" {
		if n, ok := headerCount(content, "files"); ok {
			summary = fmt.Sprintf("%d %s", n, plural(n, "file", "files"))
		}
	}
	if summary == "" {
		return ""
	}
	entries := make([]string, 0, 8)
	for _, line := range strings.Split(content, "\n")[1:] {
		if line != "" {
			entries = append(entries, line)
		}
	}
	if len(entries) == 0 {
		return summary
	}
	preview := strings.Join(entries[:min(3, len(entries))], "  ")
	if len(entries) > 3 {
		preview += fmt.Sprintf(" (+%d more)", len(entries)-3)
	}
	return summary + "\n" + preview
}

func (b Block) grepSummary(content string) string {
	if summary := summaryOf(b.Structured); summary != "" {
		return summary
	}
	if n, ok := headerCount(content, "matches"); ok {
		return fmt.Sprintf("%d %s", n, plural(n, "match", "matches"))
	}
	if strings.HasPrefix(content, "No matches found") {
		return "no matches"
	}
	return truncateForPreview(content, previewChars)
}

// answeredPair rebuilds the question→answer pair from the live structured
// payload, or from the persisted receipt lines on replay (the session disk
// format carries no structured payloads).
func (b Block) answeredPair(args map[string]any, content string) (question, answer, child string, ok bool) {
	if b.Structured["answered"] == true {
		kind := structuredString(b.Structured, "type")
		if kind != "confirm" && kind != "select" {
			kind = "input"
		}
		var options []string
		if list, isList := b.Structured["options"].([]any); isList {
			for _, v := range list {
				if option, isString := v.(string); isString {
					options = append(options, option)
				}
			}
		}
		question = oneLine(structuredString(b.Structured, "question"))
		child = structuredString(b.Structured, "child_session")
		answer = answerWord(args, kind, options)
		if answer == "" {
			answer = oneLine(structuredString(b.Structured, "answer"))
		}
		if question == "" && answer == "" {
			return "", "", "", false
		}
		return clean(question), clean(answer), child, true
	}
	question = contentValue(content, "question")
	answer = contentValue(content, "answer")
	if question == "" && answer == "" {
		return "", "", "", false
	}
	return clean(question), clean(answer), "", true
}

// answerWord renders the reply the model submitted, from the call args
// (JS answer.ts answerWord).
func answerWord(args map[string]any, kind string, options []string) string {
	switch kind {
	case "confirm":
		if value, isBool := args["confirm"].(bool); isBool {
			if value {
				return "true"
			}
			return "false"
		}
		return ""
	case "select":
		// JS reads `args.index` as a JSON number only; a string is not an index.
		index := -1
		if n, isNumber := args["index"].(float64); isNumber && n == float64(int(n)) {
			index = int(n)
		}
		if index < 0 {
			return ""
		}
		option := fmt.Sprintf("option %d", index)
		if index < len(options) {
			option = options[index]
		}
		return fmt.Sprintf("%s (index %d)", clean(option), index)
	}
	if text, isString := args["text"].(string); isString {
		return oneLine(text)
	}
	return ""
}

func structuredString(structured map[string]any, key string) string {
	if s, ok := structured[key].(string); ok {
		return s
	}
	return ""
}

func patternPrimary(s Styles, args map[string]any) string {
	if pattern := argString(args, "pattern"); pattern != "" {
		return styled(s.Pending, clean(pattern))
	}
	return "(no pattern)"
}

// resultBlock renders the shared spec-result layout: `● title primary` and an
// optional summary whose lines are each muted and indented by six columns.
func resultBlock(s Styles, state, title, primary, summary string) string {
	line := s.bullet(state) + " " + s.title(title)
	if primary != "" {
		line += " " + primary
	}
	if summary == "" {
		return line
	}
	lines := strings.Split(summary, "\n")
	for i, l := range lines {
		lines[i] = s.muted(l)
	}
	return line + "\n      " + strings.Join(lines, "\n      ")
}

// plainResultBlock is the JS fallback layout: the body sits at the Text
// component's single-column indent, not the six-column summary indent, and it
// keeps the terminal's default foreground (JS fallback.ts) instead of muted.
func plainResultBlock(s Styles, state, title, body string) string {
	line := s.bullet(state) + " " + s.title(title)
	if body == "" {
		return line
	}
	return line + "\n" + body
}

func askCallText(s Styles, state string, args map[string]any, title string) string {
	question := argString(args, "question")
	if question == "" {
		question = "(no question)"
	}
	options := stringList(args, "options")
	kind := argString(args, "type")
	if kind == "" {
		kind = "input"
		if len(options) > 0 {
			kind = "select"
		}
	}
	head := s.bullet(state) + " " + s.title(title) + " " + clean(question)
	if len(options) > 0 {
		labels := make([]string, 0, len(options))
		for _, option := range options {
			labels = append(labels, s.muted("「"+clean(option)+"」"))
		}
		return head + "\n      " + s.dim("["+kind+"]") + " " + strings.Join(labels, " ")
	}
	return head + "  " + s.dim("["+kind+"]")
}

// spawnParamsLine is the JS subagent params line: every present spawn field,
// joined by " · ". Live child badges are appended by the parent
// (decorateAgentCall), so the fields the live header shows are still listed.
func spawnParamsLine(args map[string]any) string {
	var segments []string
	if kind := argString(args, "kind"); kind != "" {
		segments = append(segments, "kind "+clean(kind))
	}
	model, effort := argString(args, "model"), argString(args, "effort")
	if model != "" {
		note := ""
		if effort != "" {
			note = "(" + clean(effort) + ")"
		}
		segments = append(segments, "model "+clean(model)+note)
	} else if effort != "" {
		segments = append(segments, "effort "+clean(effort))
	}
	if background, ok := args["background"].(bool); ok && background {
		segments = append(segments, "background")
	}
	if resume := argString(args, "resume"); resume != "" {
		segments = append(segments, "resume="+clean(resume))
	}
	if timeout, ok := argNumber(args, "timeout_ms"); ok {
		segments = append(segments, "timeout "+formatTimeout(timeout))
	}
	if tools, ok := args["tools"].([]any); ok {
		segments = append(segments, fmt.Sprintf("tools %d", len(tools)))
	}
	switch skills := args["skills"].(type) {
	case bool:
		if skills {
			segments = append(segments, "skills all")
		}
	case []any:
		segments = append(segments, fmt.Sprintf("skills %d", len(skills)))
	}
	return strings.Join(segments, " · ")
}

// formatTimeout renders a compact spawn timeout: seconds, minutes, hours.
func formatTimeout(ms float64) string {
	switch {
	case ms < 60_000:
		return fmt.Sprintf("%ds", int(round(ms/1000)))
	case ms < 3_600_000:
		return fmt.Sprintf("%dm", int(round(ms/60_000)))
	}
	return fmt.Sprintf("%dh", int(round(ms/3_600_000)))
}

func round(v float64) float64 {
	if v < 0 {
		return -round(-v)
	}
	return float64(int64(v + .5))
}

// editMode mirrors ext-edit: replace_all is omitted for single edits, so a
// missing (or false) value reads as "(single)".
func editMode(args map[string]any) string {
	switch v := args["replace_all"].(type) {
	case bool:
		if v {
			return "(all)"
		}
	case string:
		if v == "true" {
			return "(all)"
		}
	}
	return "(single)"
}

func elapsedSeconds(b Block, now time.Time) int {
	if b.Started.IsZero() {
		return 0
	}
	end := now
	if !b.Finished.IsZero() {
		end = b.Finished
	}
	if end.IsZero() {
		return 0
	}
	return max(0, int(end.Sub(b.Started).Seconds()))
}

// -- argument and content helpers -------------------------------------------

func argString(args map[string]any, keys ...string) string {
	for _, key := range keys {
		if v, ok := args[key]; ok {
			if s, ok := v.(string); ok {
				if s == "" {
					continue
				}
				return s
			}
			return fmt.Sprint(v)
		}
	}
	return ""
}

func argText(args map[string]any, fallback string, keys ...string) string {
	if text := argString(args, keys...); text != "" {
		return clean(text)
	}
	return fallback
}

func argNumber(args map[string]any, key string) (float64, bool) {
	switch v := args[key].(type) {
	case float64:
		return v, true
	case string:
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n, true
		}
	}
	return 0, false
}

func stringList(args map[string]any, key string) []string {
	values, ok := args[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, v := range values {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// summaryOf extracts the reserved `summary : String` field of a payload.
func summaryOf(structured map[string]any) string {
	if s, ok := structured["summary"].(string); ok && s != "" {
		// Summaries are runtime text rendered on the plain-result path;
		// the SGR allowlist is applied here so every caller inherits it.
		return ui.SanitizeSGR(s)
	}
	return ""
}

// headerCount reads a `Found N <noun>` header (ext-grep/ext-glob format).
func headerCount(content, noun string) (int, bool) {
	first := firstLine(content)
	const prefix = "Found "
	if !strings.HasPrefix(first, prefix) {
		return 0, false
	}
	rest := first[len(prefix):]
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits++
	}
	if digits == 0 || !strings.HasPrefix(rest[digits:], " "+noun) {
		return 0, false
	}
	n, err := strconv.Atoi(rest[:digits])
	if err != nil {
		return 0, false
	}
	return n, true
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

// contentValue reads a `key: value` line from a persisted receipt.
func contentValue(content, key string) string {
	prefix := key + ": "
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(line[len(prefix):])
		}
	}
	return ""
}

// savedPlanPath extracts the `Saved to <path>.` receipt tail.
func savedPlanPath(content string) string {
	trimmed := strings.TrimSpace(content)
	const marker = "Saved to "
	at := strings.LastIndex(trimmed, marker)
	if at < 0 {
		return ""
	}
	rest := trimmed[at+len(marker):]
	if !strings.HasSuffix(rest, ".") || strings.Contains(rest, "\n") {
		return ""
	}
	return strings.TrimSuffix(rest, ".")
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func firstLine(s string) string {
	if at := strings.IndexByte(s, '\n'); at >= 0 {
		return s[:at]
	}
	return s
}

func truncateRunes(s string, limit int) string {
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	return string(runes[:limit]) + "…"
}

func runeLen(s string) int { return len([]rune(s)) }

// truncateForPreview squeezes content onto one truncated line
// (JS truncateForPreview).
func truncateForPreview(s string, limit int) string {
	return truncateRunes(strings.ReplaceAll(s, "\n", " "), limit)
}

// previewLines pretty-prints a JSON payload and keeps the first `limit` lines
// with a `… (+N lines)` tail, exactly like the JS registry helper.
func previewLines(s string, limit int) string {
	text := prettyIfJSON(s)
	lines := strings.Split(text, "\n")
	if len(lines) <= limit {
		return text
	}
	return strings.Join(lines[:limit], "\n") + fmt.Sprintf("\n… (+%d lines)", len(lines)-limit)
}

func prettyIfJSON(s string) string {
	trimmed := strings.TrimLeft(s, " \t\r\n")
	if trimmed == "" || (trimmed[0] != '{' && trimmed[0] != '[') {
		return s
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, []byte(trimmed)); err != nil {
		return s
	}
	var indented bytes.Buffer
	if err := json.Indent(&indented, compact.Bytes(), "", "  "); err != nil {
		return s
	}
	return indented.String()
}

// -- pi-tui Text emulation --------------------------------------------------

// textLines renders what the JS host builds with `new Text(text, 1, 0)`:
// pi-tui word-wraps every physical line at width-2 and indents each rendered
// line by one column.
func textLines(text string, width int) []string {
	text = strings.ReplaceAll(text, "\t", "   ")
	if strings.TrimSpace(ansi.Strip(text)) == "" {
		return nil
	}
	pad := min(1, max(0, (width-1)/2))
	inner := max(1, width-2*pad)
	left := strings.Repeat(" ", pad)
	var out []string
	for _, line := range strings.Split(text, "\n") {
		for _, wrapped := range wrapAnsiLine(line, inner) {
			out = append(out, left+wrapped)
		}
	}
	return out
}

// bubbleLines renders the JS user bubble: `Box(1, 0, bg)` around
// `Text(prompt, 0, 0)`, so lines are padded to the full terminal width and the
// surface colour spans every cell.
func bubbleLines(text string, width int) []string {
	text = strings.ReplaceAll(text, "\t", "   ")
	inner := max(1, width-2)
	var out []string
	for _, line := range strings.Split(text, "\n") {
		for _, wrapped := range wrapAnsiLine(line, inner) {
			row := " " + wrapped
			out = append(out, row+strings.Repeat(" ", max(0, width-ansi.StringWidth(row))))
		}
	}
	return out
}

type atom struct {
	text  string
	width int
	space bool
}

type token struct {
	atoms []atom
	width int
	space bool
}

// wrapAnsiLine mirrors pi-tui's Text wrapping: greedy word wrap at the cell
// width, whole words kept together, over-long tokens hard-broken by grapheme,
// and trailing whitespace removed from every produced line.
func wrapAnsiLine(line string, limit int) []string {
	if limit < 1 || ansi.StringWidth(line) <= limit {
		return []string{line}
	}
	tokens := ansiTokens(line)
	var (
		out      []string
		cur      []token
		curWidth int
	)
	flush := func() {
		out = append(out, joinTokens(cur))
		cur, curWidth = nil, 0
	}
	for _, t := range tokens {
		if t.width > limit && !t.space {
			if curWidth > 0 {
				flush()
			}
			chunks := breakToken(t, limit)
			for _, chunk := range chunks[:len(chunks)-1] {
				out = append(out, joinTokens(chunk))
			}
			cur = chunks[len(chunks)-1]
			curWidth = tokensWidth(cur)
			continue
		}
		if curWidth+t.width > limit && curWidth > 0 {
			flush()
			if t.space {
				continue
			}
			cur, curWidth = []token{t}, t.width
			continue
		}
		cur = append(cur, t)
		curWidth += t.width
	}
	if len(cur) > 0 {
		flush()
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// ansiTokens splits a line into whitespace runs and word tokens while keeping
// escape sequences attached to the token they belong to.
func ansiTokens(line string) []token {
	var (
		tokens   []token
		p        = ansi.NewParser()
		state    byte
		rest     = line
		open     bool
		prevWide bool
	)
	start := func(space bool) {
		tokens = append(tokens, token{space: space})
		open = true
		prevWide = false
	}
	current := func() *token { return &tokens[len(tokens)-1] }
	for len(rest) > 0 {
		seq, width, n, next := ansi.DecodeSequence(rest, state, p)
		if n == 0 {
			break
		}
		state, rest = next, rest[n:]
		if width == 0 {
			// Escape sequences and controls are zero-width; they stay with the
			// token they precede so a wrap never splits them from their text.
			if !open {
				start(false)
			}
			t := current()
			t.atoms = append(t.atoms, atom{text: seq})
			continue
		}
		space := strings.TrimSpace(seq) == ""
		// Scripts without spaces (CJK, emoji) are segmented per grapheme so
		// they fill a line greedily instead of hard-breaking from column one,
		// which is how the JS word segmenter wraps them.
		wide := width > 1
		if !open || space != current().space || wide || prevWide {
			start(space)
		}
		prevWide = wide
		t := current()
		t.atoms = append(t.atoms, atom{text: seq, width: width, space: space})
		t.width += width
	}
	return tokens
}

func tokensWidth(tokens []token) int {
	width := 0
	for _, t := range tokens {
		width += t.width
	}
	return width
}

// joinTokens concatenates a rendered line and drops the trailing whitespace
// pi-tui trims from every wrapped line. Escape sequences survive the trim so a
// style can never bleed into the next row.
func joinTokens(tokens []token) string {
	var atoms []atom
	for _, t := range tokens {
		atoms = append(atoms, t.atoms...)
	}
	last := -1
	for i, a := range atoms {
		if a.width > 0 && !a.space {
			last = i
		}
	}
	var b strings.Builder
	for i, a := range atoms {
		if a.width > 0 && a.space && (last < 0 || i > last) {
			continue
		}
		b.WriteString(a.text)
	}
	return b.String()
}

// breakToken hard-breaks an over-long token into chunks of at most limit cells.
func breakToken(t token, limit int) [][]token {
	var chunks [][]token
	var cur []token
	width := 0
	appendAtom := func(a atom) {
		if len(cur) == 0 {
			cur = []token{{}}
		}
		last := &cur[len(cur)-1]
		last.atoms = append(last.atoms, a)
		last.width += a.width
	}
	for _, a := range t.atoms {
		if a.width == 0 {
			appendAtom(a)
			continue
		}
		if width+a.width > limit && width > 0 {
			chunks = append(chunks, cur)
			cur, width = nil, 0
		}
		appendAtom(a)
		width += a.width
	}
	if len(cur) > 0 {
		chunks = append(chunks, cur)
	}
	if len(chunks) == 0 {
		chunks = [][]token{{}}
	}
	return chunks
}
