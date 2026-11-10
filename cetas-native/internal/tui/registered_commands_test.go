package tui

import (
	"encoding/json"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

const commandFixture = `{"session_id":"session-a","commands":[{"id":"ptc","label":"PTC","description":"Select tool-calling mode","category":"ptc","ctype":"select","visible":true,"aliases":["program"],"params":[{"name":"action","ptype":"str","positional":true,"required":false,"choices":["on","off","hybrid"]}]},{"id":"hidden-debug","visible":false,"params":[]},{"id":"integer","description":"Limit","visible":true,"params":[{"name":"count","ptype":"int","required":true,"positional":true},{"name":"enabled","ptype":"bool","positional":false,"required":false}]}]}`

func TestDynamicCommandCatalogAndAliasSelection(t *testing.T) {
	m := newModel()
	m.session = "session-a"
	m.installCommandCatalog(json.RawMessage(commandFixture))
	if len(m.dynamicCommands) != 3 {
		t.Fatalf("expected composed registry got %#v", m.dynamicCommands)
	}
	found := m.commandSuggestions("/pt")
	if len(found) == 0 || found[0].insert != "/ptc" {
		t.Fatalf("dynamic command unavailable: %#v", found)
	}
	alias := m.commandSuggestions("/prog")
	if len(alias) == 0 || alias[0].insert != "/program" {
		t.Fatalf("alias missing: %#v", alias)
	}
	if got := m.commandInsertion("/program"); got != "/program " {
		t.Fatalf("alias insertion: %q", got)
	}
	if len(m.commandSuggestions("/hidden")) != 0 {
		t.Fatal("hidden commands should not be advertised")
	}
	choices := m.commandSuggestions("/ptc o")
	if len(choices) != 2 || choices[0].insert != "/ptc on" || choices[1].insert != "/ptc off" {
		t.Fatalf("parameter choices missing: %#v", choices)
	}
	m.session = "session-b"
	if _, found := m.lookupCommand("/ptc"); found {
		t.Fatal("stale command catalog survived session switch")
	}
	m.installCommandCatalog(json.RawMessage(commandFixture))
	if m.commandSession == "session-b" {
		t.Fatal("late catalog was installed for different session")
	}
}
func TestCommandPaletteTabDoesNotExecuteOnSelection(t *testing.T) {
	m := newModel()
	m.session = "session-a"
	m.installCommandCatalog(json.RawMessage(commandFixture))
	m.lastProgramStatus = formatProgramStatus(m.projectProgramStatus())
	m.modal = "slash"
	m.modalItems = []string{"/program"}
	m.modalValues = []string{"/program"}
	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	state := next.(model)
	if cmd != nil || state.textarea.Value() != "/program " {
		t.Fatalf("command palette Tab dispatched instead of editing: %q", state.textarea.Value())
	}
}

func TestNeedsInputReopensTypedCommandWithoutStartingAnotherTurn(t *testing.T) {
	m := newModel()
	m.session = "session-a"
	m.installCommandCatalog(json.RawMessage(commandFixture))
	m.applyEvent(event(`{"type":"command.completed","session_id":"session-a","command_id":"ptc","outcome":{"type":"needs_input","prompt":"Select a PTC mode"}}`))
	if m.textarea.Value() != "/ptc " || m.status != "Select a PTC mode" {
		t.Fatalf("needs-input outcome did not offer command editor: editor=%q status=%q", m.textarea.Value(), m.status)
	}
	found := m.commandSuggestions(m.textarea.Value())
	if len(found) != 3 {
		t.Fatalf("typed choices missing: %#v", found)
	}
	m.session = "session-b"
	m.applyEvent(event(`{"type":"command.completed","session_id":"session-a","command_id":"ptc","outcome":{"type":"success","feedback":"stale"}}`))
	if strings.Contains(strings.Join(m.transcript, "\n"), "stale") {
		t.Fatal("stale command response crossed session boundary")
	}
}
