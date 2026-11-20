package localipc

import (
	"os"
	"strings"
)

// OwnerLeaseEnabled controls best-effort local owner election. Local
// collaboration is attempted automatically, but it is NEVER a prerequisite
// for Cetas startup. Explicit 0/false/no/off disables all owner IPC;
// lease/socket failures only produce diagnostics and standalone Cetas works.
func OwnerLeaseEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CETAS_IPC_OWNER"))) {
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}
