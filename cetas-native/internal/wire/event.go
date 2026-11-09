// Package wire defines the transport-neutral native console event envelope.
package wire

import "encoding/json"

// Event retains the complete original frame. Consumers decode only the
// presentation fields they understand; no runtime pointers cross this seam.
type Event struct {
	Type string
	Raw  json.RawMessage
}
