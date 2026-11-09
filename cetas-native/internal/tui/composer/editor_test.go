package composer

import (
	tea "charm.land/bubbletea/v2"
	"strings"
	"testing"
)

func key(code rune, mod tea.KeyMod) tea.KeyPressMsg { return tea.KeyPressMsg{Code: code, Mod: mod} }
func TestPasteIsOneUndoableEditAndSubmissionRetainsOriginal(t *testing.T) {
	m := New()
	m.SetWidth(40)
	m.Focus()
	text := strings.Repeat("你好 👋\n", 12)
	m, _ = m.Update(tea.PasteMsg{Content: text})
	if !strings.Contains(m.Value(), "[paste #1") {
		t.Fatalf("long paste must be a chip, got %q", m.Value())
	}
	if m.Submission() != text {
		t.Fatalf("paste submission corrupted: %q", m.Submission())
	}
	m, _ = m.Update(key('-', tea.ModCtrl))
	if m.Submission() != "" {
		t.Fatalf("one undo must undo entire paste: %q", m.Submission())
	}
}
func TestHistoryRestoresUnsubmittedDraft(t *testing.T) {
	m := New()
	m.Remember("first")
	m.Remember("second")
	m.SetValue("draft")
	m, _ = m.Update(key(tea.KeyUp, 0))
	if m.Value() != "second" {
		t.Fatalf("history: %q", m.Value())
	}
	m, _ = m.Update(key(tea.KeyDown, 0))
	if m.Value() != "draft" {
		t.Fatalf("draft lost: %q", m.Value())
	}
}
func TestKillAndYankPreserveUnicode(t *testing.T) {
	m := New()
	m.Focus()
	m.SetValue("你好 world")
	m.MoveToEnd()
	m, _ = m.Update(key('w', tea.ModCtrl))
	if m.Value() != "你好 " {
		t.Fatalf("kill: %q", m.Value())
	}
	m, _ = m.Update(key('y', tea.ModCtrl))
	if m.Value() != "你好 world" {
		t.Fatalf("yank: %q", m.Value())
	}
}
func TestReleaseDoesNotEdit(t *testing.T) {
	m := New()
	m.SetValue("safe")
	next, _ := m.Update(tea.KeyReleaseMsg{Code: tea.KeyBackspace})
	if next.Value() != "safe" {
		t.Fatal("release deleted text")
	}
}
