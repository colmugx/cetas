package localipc

import (
	"os"
	"strings"
)

// OwnerLeaseEnabled gates unfinished cross-process ownership integration.
// A native Cetas starts normally when no IPC owner service is available:
// only explicit opt-in requests the experimental single-owner lease.
// The existing process-local Harness singleton remains unconditional.
func OwnerLeaseEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CETAS_IPC_OWNER"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
