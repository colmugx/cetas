// Package nativepi runs allowlisted Pi extensions in a supervised Bun
// subprocess. MoonBit/Posoco retains authority over tool admission and execution.
package nativepi

import "encoding/json"

// Tool is the guest's catalog descriptor. Parameters must not be weakened,
// projected or trusted as already validated: the Posoco kernel owns validation.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

type Result struct {
	OK      bool   `json:"ok"`
	Content string `json:"content"`
	Details any    `json:"details,omitempty"`
}
