package tui

// A native-only, muted transcript notice. This is not a persisted Agent
// message and is never injected into the cetas-js renderer or kernel.

func (m *model) nativePiUnavailable() bool {
	if m.host == nil {
		return false
	}
	capability, ok := m.host.(interface{ PiAvailable() bool })
	return ok && !capability.PiAvailable()
}
