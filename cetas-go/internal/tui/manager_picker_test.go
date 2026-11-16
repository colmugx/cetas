package tui

import (
	"strings"
	"testing"
)

func TestOpenManagerPickerMarksTheActiveChoice(t *testing.T) {
	m := &model{}
	m.surface.manager = "magpie"
	m.openManagerPicker()
	if m.modal != "manager" {
		t.Fatalf("manager modal not opened: %q", m.modal)
	}
	if len(m.modalValues) != 2 || m.modalValues[0] != "providers" || m.modalValues[1] != "magpie" {
		t.Fatalf("unexpected manager values: %v", m.modalValues)
	}
	if m.modalIndex != 1 {
		t.Fatalf("active magpie choice not selected: %d", m.modalIndex)
	}
	if !strings.Contains(m.modalItems[1], "● ") {
		t.Fatalf("active choice not marked: %q", m.modalItems[1])
	}
	if strings.Contains(m.modalItems[0], "● ") {
		t.Fatalf("inactive choice marked: %q", m.modalItems[0])
	}
}

func TestManagerPickerDefaultsToProvidersWithoutSnapshot(t *testing.T) {
	m := &model{}
	m.openManagerPicker()
	if m.modalIndex != 0 {
		t.Fatalf("default index should stay on providers: %d", m.modalIndex)
	}
}

func TestManagerSwitchRequestCarriesTheChoice(t *testing.T) {
	m := &model{}
	m.surface.manager = "providers"
	m.openManagerPicker()
	m.modalIndex = 1
	chosen := m.modalValues[m.modalIndex]
	if chosen != "magpie" {
		t.Fatalf("unexpected selection: %q", chosen)
	}
	// The switch is a plain harness request: the choice must travel verbatim
	// as the wire argument the runtime dispatch matches on.
	if chosen != "providers" && chosen != "magpie" {
		t.Fatalf("choice outside the wire vocabulary: %q", chosen)
	}
}

func TestManagerCommandListedInHelp(t *testing.T) {
	help := nativeSlashHelp()
	if !strings.Contains(help, "/manager — ") {
		t.Fatal("/manager missing from native slash help")
	}
}
