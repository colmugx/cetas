package wire

import "encoding/json"

// SessionObservation represents one read-only stream from the real owning
// Runtime. Closing it never starts a new Agent or alters the owner Session.
type SessionObservation struct {
	Snapshot json.RawMessage
	Events <-chan Event
	Close func() error
}
