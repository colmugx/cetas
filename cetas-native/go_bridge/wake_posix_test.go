//go:build !windows

package bridge

import (
	"syscall"
	"testing"
)

// A transferred command descriptor belongs to the scheduler: probing or
// reading the recycled fd number would race its close and reuse.
func TestTransferredCommandDescriptorCannotBeProbedOrRead(t *testing.T) {
	if isolatedCommandChannel(t, "TestTransferredCommandDescriptorCannotBeProbedOrRead") {
		return
	}
	h := transportUnderTest()
	if err := h.Send(CommandStop); err != nil {
		t.Fatal(err)
	}
	fd := claimCommandChannel()
	if fd < 0 {
		t.Fatal("command read end was not transferred")
	}
	defer syscall.Close(fd)
	if commandChannelLive() || commandWakePending() {
		t.Fatal("test seam touched a descriptor already owned by the scheduler")
	}
	if claimCommandChannel() >= 0 {
		t.Fatal("command descriptor ownership was transferred twice")
	}
}
