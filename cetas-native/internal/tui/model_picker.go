package tui

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"encoding/json"
	"github.com/colmugx/cetas/cetas-native/internal/tui/overlays"
	"time"
)

func (m *model) syncModelPicker() {
	m.modalIndex = m.modelPicker.Index
	m.modalItems = m.modelPicker.Labels()
	m.modalPrompt = m.modelPicker.Title()
	m.modalValues = nil
	for _, row := range m.modelPicker.Rows() {
		m.modalValues = append(m.modalValues, row.ID)
	}
}
func (m *model) openModelPicker() {
	m.modelPicker = overlays.NewModels(m.modelSlots)
	m.syncModelPicker()
}
func (m *model) modelPickerKey(key, text string) bool {
	if m.modal != "models" || m.modalRequestID != "" {
		return false
	}
	if key == "enter" {
		return false
	}
	m.modelPicker.Index = m.modalIndex
	if !m.modelPicker.Key(key, text) {
		return false
	}
	m.syncModelPicker()
	return true
}
func (m *model) chooseModel(id string) tea.Cmd {
	m.modelPicker.Index = m.modalIndex
	selected := m.modelPicker.Selection()
	effort := ""
	if selected != nil && selected.ID == id {
		effort = selected.Effort
	}
	host := m.host
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		raw, err := host.Request(ctx, "switch_model", map[string]any{"slot_id": id})
		var failure struct {
			Error string `json:"error"`
		}
		if err == nil && json.Unmarshal(raw, &failure) == nil && failure.Error == "" && effort != "" {
			raw, err = host.Request(ctx, "select_effort", map[string]any{"effort": effort})
		}
		return commandResult{name: "switch_model", payload: raw, err: err}
	}
}
