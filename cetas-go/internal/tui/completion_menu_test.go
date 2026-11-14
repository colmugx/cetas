package tui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestCompletionMenuGrowsToItsCapOnly(t *testing.T) {
	const width = 48
	m := newModel()
	m.modal = "files"
	if !m.completing() {
		t.Fatal("a files modal must count as an active completion")
	}
	for _, count := range []int{1, 3, 6, 40} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			m.modalItems = make([]string, count)
			for i := range m.modalItems {
				m.modalItems[i] = fmt.Sprintf("file-%02d.go", i)
			}
			m.modalIndex = 0
			rows := completionMenu(m.theme(), m.modalItems, m.modalIndex, width)
			want := min(count, completionMenuRows)
			if len(rows) != want {
				t.Fatalf("%d results painted %d rows, want %d", count, len(rows), want)
			}
			for i, row := range rows {
				if got := ansi.StringWidth(row); got != width {
					t.Fatalf("row %d width = %d, want %d: %q", i, got, width, row)
				}
			}
			if !strings.Contains(ansi.Strip(rows[0]), "→ file-00.go") {
				t.Fatalf("%d results lost the selected row: %q", count, ansi.Strip(rows[0]))
			}
		})
	}
}

func TestCompletionInstallsBestMatchAtTheBottom(t *testing.T) {
	m := newModel()
	m.installCompletion("files", []string{"best.go", "mid.go", "last.go"}, []string{"best.go", "mid.go", "last.go"})
	if len(m.modalItems) != 3 || m.modalItems[0] != "last.go" || m.modalItems[2] != "best.go" {
		t.Fatalf("candidates not reversed: %v", m.modalItems)
	}
	if m.modalIndex != 2 {
		t.Fatalf("cursor starts at %d, want the bottom row 2", m.modalIndex)
	}
	if m.modalValues[m.modalIndex] != "best.go" {
		t.Fatalf("the bottom row must insert the best match: %v", m.modalValues)
	}
	before := m.modal
	m.installCompletion("files", nil, nil)
	if m.modal != before || m.modalItems == nil {
		t.Fatal("an empty candidate set must not touch the completion state")
	}
}

func TestCompletionMenuKeepsTheCursorRowVisible(t *testing.T) {
	const width = 48
	m := newModel()
	m.modal = "files"
	m.modalItems = make([]string, 40)
	for i := range m.modalItems {
		m.modalItems[i] = fmt.Sprintf("file-%02d.go", i)
	}
	m.modalIndex = 39
	rows := completionMenu(m.theme(), m.modalItems, m.modalIndex, width)
	if len(rows) != completionMenuRows {
		t.Fatalf("long list painted %d rows, want %d", len(rows), completionMenuRows)
	}
	if last := ansi.Strip(rows[len(rows)-1]); !strings.Contains(last, "→ file-39.go") {
		t.Fatalf("modalIndex 39 scrolled out of the pane: %#v", ansi.Strip(strings.Join(rows, "|")))
	}
}

func TestCompletionMenuIsAbsentWithoutResults(t *testing.T) {
	m := newModel()
	m.modal = "files"
	m.modalItems = nil
	if got := completionMenu(m.theme(), m.modalItems, 0, 40); got != nil {
		t.Fatalf("an empty completion painted a pane: %#v", got)
	}
	m.closeCompletion()
	if m.completing() {
		t.Fatal("a closed completion still claims the menu")
	}
	if menu := m.regions().menu; menu != nil {
		t.Fatalf("a closed completion reserved menu rows: %#v", menu)
	}
}
