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
