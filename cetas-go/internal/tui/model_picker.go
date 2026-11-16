package tui

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"encoding/json"
	"github.com/colmugx/cetas/cetas-go/internal/tui/overlays"
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

// openManagerPicker installs the static two-choice manager dialog. The active
// choice comes from the last runtime snapshot; a snapshot that never carried
// model_manager (older runtime) simply shows no marker.
func (m *model) openManagerPicker() {
	items := []string{"Providers — ext-llm slot router", "Magpie — Magpie Gateway model manager"}
	values := []string{"providers", "magpie"}
	m.modalIndex = 0
	for i, v := range values {
		if v == m.surface.manager {
			items[i] = "● " + items[i]
			m.modalIndex = i
		}
	}
	m.modal = "manager"
	m.modalItems = items
	m.modalValues = values
	m.modalPrompt = "Select model manager"
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
