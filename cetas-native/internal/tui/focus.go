package tui

// UI requests are FIFO obligations. A correlated catalog reply must not
// replace their kind while leaving the request id attached to another picker.
func opensDialog(reply string) bool {
	switch reply {
	case "models", "sessions", "providers", "rewind_points", "skills_browse":
		return true
	}
	return false
}

// sessionPickerFocused reports whether the typed `/sessions` picker owns input.
// A UiPort ask is the first focus owner in FIFO order, so it — and any dialog
// that took the screen while the ask is outstanding — keeps focus; the picker
// waits behind it and receives keys again once the ask is answered. The
// completion popups share the modal field, so they win the same way.
func (m model) sessionPickerFocused() bool {
	return m.sessionPicker.open && m.modal == "" && m.modalRequestID == ""
}
