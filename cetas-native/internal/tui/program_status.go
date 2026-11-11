package tui

import (
	"encoding/base64"
	"path/filepath"
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
)

// OSC 7501 program-status reporting (rex program-status spec). One root program
// tells a supporting terminal whether it is idle, working or blocked on the
// user; spec-compliant terminals silently ignore the sequence, so emission is
// unconditional and deduped. Wire format:
//
//	ESC ] 7501 ; state=<s>:app=cetas[:kind=<k>][:msg=<base64 UTF-8>] ESC \
//
// `kind` rides blocked reports only; `msg` strips control characters, trims,
// and is base64-encoded with a 2048-byte decoded budget.

type programStatus struct {
	state string // idle | working | done | blocked | error | clear
	kind  string // auth | question, blocked reports only
	msg   string
	title string // label reported with every record; the window title shares it
}

// Authentication outranks questions, and questions outrank setup.
func (m model) projectProgramStatus() programStatus {
	pendingQuestions := len(m.pendingUI)
	if m.modalRequestID != "" {
		pendingQuestions++
	}
	report := func(state, kind, msg string) programStatus {
		return programStatus{state: state, kind: kind, msg: msg, title: m.programTitle()}
	}
	switch {
	case m.status == "MoonBit host stopped":
		// Clear carries no record keys; the terminal drops the record whole.
		return programStatus{state: "clear"}
	case m.authID != "":
		return report("blocked", "auth", "Waiting for authentication")
	case pendingQuestions > 0:
		return report("blocked", "question", "Waiting for your response")
	case m.needsSetup:
		return report("blocked", "auth", "Connect a model provider")
	case m.running || m.switchInFlight != "":
		return report("working", "", "Working")
	case m.turnOutcome == turnFailed:
		// error survives until the user looks; the next activity replaces it.
		return report("error", "", m.turnOutcomeDetail)
	case m.turnOutcome == turnDone:
		return report("done", "", m.turnOutcomeDetail)
	case m.session != "":
		return report("idle", "", "")
	default:
		return report("working", "", "Starting")
	}
}

// The same workspace composition the OSC 2 title shows, so the terminal's two
// views agree.
func (m model) programTitle() string {
	title := "cetas"
	if base := filepath.Base(strings.TrimSpace(m.surface.cwd)); base != "" && base != "." && base != "/" {
		title = "cetas · " + base
	}
	return title
}

// Terminals discard reports whose text contains control characters, so msg and
// title are cleaned before encoding.
func formatProgramStatus(status programStatus) string {
	pairs := []string{"state=" + status.state}
	if matchAppID("cetas") {
		pairs = append(pairs, "app=cetas")
	}
	if status.state == "blocked" && status.kind != "" {
		pairs = append(pairs, "kind="+status.kind)
	}
	if message := truncateStatusMessage(status.msg); message != "" {
		pairs = append(pairs, "msg="+base64.StdEncoding.EncodeToString([]byte(message)))
	}
	if title := truncateStatusTitle(status.title); title != "" {
		pairs = append(pairs, "title="+base64.StdEncoding.EncodeToString([]byte(title)))
	}
	return "\x1b]7501;" + strings.Join(pairs, ":") + "\x1b\\"
}

// The protocol's msg budget: control characters become spaces, surrounding
// space is trimmed, at most 2048 UTF-8 bytes survive.
func truncateStatusMessage(text string) string {
	cleaned := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return ' '
		}
		return r
	}, text)
	cleaned = strings.TrimSpace(cleaned)
	for utf8.RuneCountInString(cleaned) > 0 && len(cleaned) > 2048 {
		_, size := utf8.DecodeLastRuneInString(cleaned)
		cleaned = cleaned[:len(cleaned)-size]
	}
	return cleaned
}

// The protocol's title budget: 192 decoded bytes, same cleaning as msg.
func truncateStatusTitle(text string) string {
	cleaned := truncateStatusMessage(text)
	for utf8.RuneCountInString(cleaned) > 0 && len(cleaned) > 192 {
		_, size := utf8.DecodeLastRuneInString(cleaned)
		cleaned = cleaned[:len(cleaned)-size]
	}
	return cleaned
}

// The protocol's app-name pattern; the check keeps an invalid id off the wire.
func matchAppID(app string) bool {
	if len(app) == 0 || len(app) > 32 {
		return false
	}
	for _, r := range app {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '_' || r == '.' || r == '+' || r == '-':
		default:
			return false
		}
	}
	return true
}

// tea.Raw is renderer-coordinated, so the sequence never interleaves with a
// frame in flight.
func (m *model) emitProgramStatus() tea.Cmd {
	report := formatProgramStatus(m.projectProgramStatus())
	if report == m.lastProgramStatus {
		return nil
	}
	m.lastProgramStatus = report
	return tea.Raw(report)
}
