package harness

import (
	"context"
	"strings"
	"testing"
)

func TestObserveSessionDoesNotCreateAWriterWithoutAnOwner(t *testing.T) {
	h := newHost(nil)
	defer h.pi.close()
	if _, err := h.ObserveSession(context.Background(), "session-a"); err == nil ||
		!strings.Contains(err.Error(), "no competing local Session owner") {
		t.Fatalf("observation unexpectedly started a new runtime: %v", err)
	}
}
