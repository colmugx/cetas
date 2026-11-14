package tui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

// pi-tui Editor.handleInput confirms slash completion and falls through to
// submit on Enter; Tab only applies the completion. Non-slash completions
// return without submitting (editor.js, autocomplete-mode branch).
func TestSlashCompletionEnterSubmitsInOnePhysicalKey(t *testing.T) {
	for _, draft := range []string{"/ne", "/new"} {
		t.Run(draft, func(t *testing.T) {
			m := newModel()
			m.host = &testHost{}
			for _, r := range draft {
				next, _ := m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
				m = next.(model)
			}
			if m.modal != "slash" {
				t.Fatal("typing did not open slash completion")
			}
			next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
			state := next.(model)
			if cmd == nil {
				t.Fatal("Enter completed the command but did not submit it")
			}
			result, ok := cmd().(commandResult)
			if !ok || result.name != "new_session" {
				t.Fatalf("wrong command dispatch: %#v", result)
			}
			if state.textarea.Value() != "" || state.modal != "" || len(state.transcript) != 0 {
				t.Fatalf("slash command left a draft or became a user turn: draft=%q modal=%q transcript=%#v", state.textarea.Value(), state.modal, state.transcript)
			}
		})
	}
}

func TestCompletionTabAndNonSlashEnterOnlyInsert(t *testing.T) {
	for _, tc := range []struct {
		name, modal, value, want string
		key                      rune
	}{
		{"slash-tab", "slash", "/model", "/model", tea.KeyTab},
		{"skill-enter", "skills", "inspect", "$inspect ", tea.KeyEnter},
		{"file-enter", "files", "README.md", "@README.md ", tea.KeyEnter},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newModel()
			m.host = &testHost{}
			// Seed the terminal status report so the only possible command
			// from this Update is a completion side effect.
			m.lastProgramStatus = formatProgramStatus(m.projectProgramStatus())
			m.modal = tc.modal
			m.modalItems = []string{tc.value}
			m.modalValues = []string{tc.value}
			next, cmd := m.Update(tea.KeyPressMsg{Code: tc.key})
			state := next.(model)
			if cmd != nil || state.textarea.Value() != tc.want || state.modal != "" || len(state.transcript) != 0 {
				t.Fatalf("completion submitted unexpectedly: draft=%q modal=%q cmd=%v", state.textarea.Value(), state.modal, cmd != nil)
			}
		})
	}
}
