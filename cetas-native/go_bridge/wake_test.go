package bridge

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// waitInBackground starts one Wait and reports when it returns.
func waitInBackground(h *Infra) <-chan error {
	done := make(chan error, 1)
	go func() { done <- h.Wait() }()
	return done
}

// settle fails unless a blocked Wait is still blocked after d, so a test can
// prove the wakeup it observes later is caused by its own producer.
func settle(t *testing.T, done <-chan error, d time.Duration) {
	t.Helper()
	select {
	case err := <-done:
		t.Fatalf("Wait returned before the producer signalled (%v)", err)
	case <-time.After(d):
	}
}

func expectWake(t *testing.T, done <-chan error, what string, limit time.Duration) {
	t.Helper()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("%s: wait error: %v", what, err)
		}
	case <-time.After(limit):
		t.Fatalf("%s did not wake the consumer", what)
	}
}

// takeCommands empties the process-wide command queue earlier transport tests
// may have filled, so this test observes only its own Send.
func takeCommands() {
	for takeCommand() != 0 {
	}
}

// Wait must replace the fixed 2ms pump ticker: it blocks until the producer
// signals, and a signal that lands while nobody waits must not be lost.
func TestWaitWakesOnPublish(t *testing.T) {
	h := transportUnderTest()
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	// Notification written before anyone waits: the next Wait returns at once.
	drainWake()
	if publishFrame([]byte(`{"type":"infra.ping"}`)) != 1 {
		t.Fatal("publish failed")
	}
	expectWake(t, waitInBackground(h), "an already-signalled queue", 2*time.Second)

	frames := drainAll(t, h)
	if len(frames) != 1 {
		t.Fatalf("expected the published frame, got %d", len(frames))
	}

	// A blocked Wait wakes on a later publish instead of spinning.
	drainWake()
	done := waitInBackground(h)
	settle(t, done, 20*time.Millisecond)
	go func() {
		time.Sleep(5 * time.Millisecond)
		publishFrame([]byte(`{"type":"infra.state"}`))
	}()
	expectWake(t, done, "a later publish", 2*time.Second)
	if got := drainAll(t, h); len(got) != 1 {
		t.Fatalf("expected the later frame, got %d", len(got))
	}
}

// Stopping is a wake path of its own: the MoonBit loop waits on its command
// channel, and the stop command has to end that wait. Submitting a harness
// request uses the same channel.
func TestSendAndSubmitWakeCommandChannel(t *testing.T) {
	if isolatedCommandChannel(t, "TestSendAndSubmitWakeCommandChannel") {
		return
	}
	if !commandChannelLive() {
		t.Fatal("fresh process has no command-channel read end")
	}
	h := transportUnderTest()
	takeCommands()
	for commandWakePending() {
	}
	if err := h.Send(CommandStop); err != nil {
		t.Fatalf("send stop: %v", err)
	}
	if !commandWakePending() {
		t.Fatal("the stop command did not wake the scheduler's command channel")
	}
	if code := takeCommand(); code != CommandStop {
		t.Fatalf("queued command = %d, want stop", code)
	}
	for commandWakePending() {
	}
	request := []byte(`{"id":1,"command":"health","args":{}}`)
	if err := h.Submit(request); err != nil {
		t.Fatalf("submit: %v", err)
	}
	if !commandWakePending() {
		t.Fatal("a harness request did not wake the scheduler's command channel")
	}
	if got := takeHarness(); !bytes.Equal(got, request) {
		t.Fatalf("queued request = %q", got)
	}
}

// Command-channel tests get a fresh process, never skip an assertion based on
// whether the singleton scheduler happened to run earlier in this package.
func isolatedCommandChannel(t *testing.T, name string) bool {
	t.Helper()
	const key = "CETAS_NATIVE_COMMAND_CHANNEL_TEST"
	if os.Getenv(key) == name {
		return false
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, "-test.run=^"+name+"$", "-test.count=1")
	cmd.Env = append(os.Environ(), key+"="+name)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("isolated command channel: %v\n%s", err, output)
	}
	return true
}

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

// A rejected publish is diagnostic information the pump must act on, so it
// wakes the consumer even though nothing was queued.
func TestWaitWakesOnRejectedPublish(t *testing.T) {
	h := transportUnderTest()
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	drainWake()
	done := waitInBackground(h)
	settle(t, done, 20*time.Millisecond)
	if rc := publishFrame(nil); rc != -1 {
		t.Fatalf("invalid publish rc=%d", rc)
	}
	expectWake(t, done, "a rejected publish", 2*time.Second)
	if len(drainAll(t, h)) != 0 {
		t.Fatal("a rejected publish must not queue a frame")
	}
}

// A stall in the bounded wait is a lost delivery the pump must report, so the
// timed-out publish wakes the consumer too.
func TestWaitWakesOnQueueFullTimeout(t *testing.T) {
	h := transportUnderTest()
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	for i := 0; i < QueueFrameCap; i++ {
		if publishFrame([]byte("x")) != 1 {
			t.Fatal("fill failed")
		}
	}
	drainWake()
	done := waitInBackground(h)
	settle(t, done, 20*time.Millisecond)
	rejected := make(chan int, 1)
	go func() { rejected <- publishFrame(testPayload(t, FrameLimit)) }()
	expectWake(t, done, "the bounded-wait timeout", 10*time.Second)
	if rc := <-rejected; rc != 0 {
		t.Fatalf("over-full publish rc=%d, want the timeout verdict", rc)
	}
	if len(drainAll(t, h)) != QueueFrameCap {
		t.Fatal("the timed-out publish disturbed the queue")
	}
}

// Wake is the host's own doorbell: the runtime owner calls it as it exits so
// a blocked pump cannot outlive the scheduler it is consuming.
func TestWakeReleasesWaiter(t *testing.T) {
	h := transportUnderTest()
	drainWake()
	done := waitInBackground(h)
	settle(t, done, 20*time.Millisecond)
	if err := h.Wake(); err != nil {
		t.Fatalf("wake: %v", err)
	}
	expectWake(t, done, "Host wake", 2*time.Second)
}
