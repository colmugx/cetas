package tui

// A native-only, muted transcript notice. This is not a persisted Agent
// message and is never injected into the cetas-js renderer or kernel.
const nativePiHint = "你正在使用 cetas-go。需要在 /experimental 安装并启用 Bun Runtime，才能获得 Pi adaptor 的能力。"

func (m *model) nativePiUnavailable() bool {
	if m.host == nil {
		return false
	}
	capability, ok := m.host.(interface{ PiAvailable() bool })
	return ok && !capability.PiAvailable()
}
