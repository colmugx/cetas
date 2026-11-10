package bridge

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

// The tests below drive the real C transport (go_bridge/host.c) through the
// production Go bindings. They never boot the MoonBit runtime: publish,
// poll and the rejection counters are pure C, so a legitimate oversized
// snapshot or burst can be reproduced deterministically.

func testPayload(t *testing.T, n int) []byte {
	t.Helper()
	payload := make([]byte, n)
	for i := 0; i+4 <= n; i += 4 {
		binary.LittleEndian.PutUint32(payload[i:], uint32(i)*2654435761)
	}
	return payload
}

func transportUnderTest() *Infra { return &Infra{} }

func publishFrame(b []byte) int { return publish(b) }

// drainAll reads every queued frame; it fails the test if reassembly ever
// errors, and returns the frames in arrival order.
func drainAll(t *testing.T, h *Infra) [][]byte {
	t.Helper()
	var frames [][]byte
	for {
		frame, err := h.Poll()
		if err != nil {
			t.Fatalf("poll: %v", err)
		}
		if frame == nil {
			return frames
		}
		frames = append(frames, frame)
	}
}

func snapshotRejections(t *testing.T, h *Infra) Rejections {
	t.Helper()
	before := h.Rejections()
	if total := h.DroppedEvents(); total != int(before.Total()) {
		t.Fatalf("drop total %d disagrees with split counters %+v", total, before)
	}
	return before
}

func assertQuiet(t *testing.T, h *Infra, before Rejections) {
	t.Helper()
	if r := h.Rejections(); r != before {
		t.Fatalf("unexpected rejections: %+v (before %+v)", r, before)
	}
}

// A synthetic snapshot larger than one wire chunk reproduces the old size
// failure: it must still arrive whole through chunk framing.
func TestChunkedSnapshotRoundTrip(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("queue was not empty at start: %d frame(s)", len(got))
	}

	const size = ChunkLimit + 37856 // crosses the single-chunk bound
	snapshot, err := json.Marshal(map[string]any{
		"type": "harness.response", "id": 42,
		"result": map[string]any{"session_id": "large-fixture", "messages": []any{map[string]any{"role": "assistant", "content": strings.Repeat("long tool result\n", size/16+1)}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot) <= ChunkLimit {
		t.Fatal("fixture did not cross the chunk bound")
	}
	if rc := publishFrame(snapshot); rc != 1 {
		t.Fatalf("oversize snapshot publish rejected: rc=%d rejections=%+v", rc, h.Rejections())
	}

	small := []byte(`{"type":"infra.ping"}`)
	if rc := publishFrame(small); rc != 1 {
		t.Fatalf("small publish rejected: rc=%d", rc)
	}
	if rc := publishFrame(snapshot); rc != 1 {
		t.Fatalf("second snapshot publish rejected: rc=%d", rc)
	}

	frames := drainAll(t, h)
	if len(frames) != 3 {
		t.Fatalf("expected 3 frames, got %d", len(frames))
	}
	if !bytes.Equal(frames[0], snapshot) || !bytes.Equal(frames[2], snapshot) {
		t.Fatalf("chunked snapshot lost bytes: got %d/%d bytes", len(frames[0]), size)
	}
	if !bytes.Equal(frames[1], small) {
		t.Fatalf("small frame corrupted between chunked frames: %q", frames[1])
	}
	assertQuiet(t, h, before)
}

// The reassembly bound must hold exactly: 4 MiB crosses, one byte more is a
// counted oversized rejection, never a silent truncation.
func TestFrameLimitBoundary(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("queue was not empty at start: %d frame(s)", len(got))
	}

	full := testPayload(t, FrameLimit)
	if rc := publishFrame(full); rc != 1 {
		t.Fatalf("4 MiB frame publish rejected: rc=%d rejections=%+v", rc, h.Rejections())
	}
	frames := drainAll(t, h)
	if len(frames) != 1 || len(frames[0]) != FrameLimit || !bytes.Equal(frames[0], full) {
		t.Fatalf("4 MiB frame did not survive reassembly: %d frame(s)", len(frames))
	}

	if rc := publishFrame(testPayload(t, FrameLimit+1)); rc != -1 {
		t.Fatalf("publish past the frame limit must be rejected: rc=%d", rc)
	}
	if r := h.Rejections(); r.Oversized != before.Oversized+1 {
		t.Fatalf("oversized rejection not counted exactly: %+v", r)
	}
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("rejected frame leaked into the queue: %d frame(s)", len(got))
	}
	assertQuiet(t, h, before.Add(Rejections{Oversized: 1}))
}

// A stalled consumer exhausts the finite wait; retain 256 frames and reject the rest,
// counted under QueueFull only — never under "oversized or queue full".
func TestBurstOverflowCountsQueueFullExactly(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("queue was not empty at start: %d frame(s)", len(got))
	}

	const burst = QueueFrameCap + 1
	accepted := 0
	for i := 0; i < burst; i++ {
		frame := []byte{byte(i)}
		switch rc := publishFrame(frame); rc {
		case 1:
			accepted++
		case 0:
		default:
			t.Fatalf("burst publish returned %d", rc)
		}
	}
	if accepted != QueueFrameCap {
		t.Fatalf("queue accepted %d frames, bound is %d", accepted, QueueFrameCap)
	}
	r := h.Rejections()
	if r.QueueFull != before.QueueFull+burst-QueueFrameCap {
		t.Fatalf("queue-full rejections not exact: %+v", r)
	}
	if r.Oversized != before.Oversized || r.Invalid != before.Invalid {
		t.Fatalf("burst must not be miscounted as oversized/invalid: %+v", r)
	}

	frames := drainAll(t, h)
	if len(frames) != QueueFrameCap {
		t.Fatalf("drained %d frames, want %d", len(frames), QueueFrameCap)
	}
	for i, frame := range frames {
		if len(frame) != 1 || frame[0] != byte(i) {
			t.Fatalf("burst frame %d corrupted: %v", i, frame)
		}
	}
	assertQuiet(t, h, before.Add(Rejections{QueueFull: burst - QueueFrameCap}))
}

// A chunk run that does not fit the bounded queue is rejected whole:
// nothing partial is ever queued, the loss counts once as queue-full, and
// every earlier and later frame stays intact — a drop can never corrupt or
// strand a half frame in front of the reader.
func TestInterruptedChunkRunSelfHeals(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("queue was not empty at start: %d frame(s)", len(got))
	}

	for i := 0; i < QueueFrameCap-1; i++ {
		if rc := publishFrame([]byte{byte(i)}); rc != 1 {
			t.Fatalf("queue filler publish rc=%d at %d", rc, i)
		}
	}
	// One free slot is left, but a frame one byte over one chunk needs two
	// chunk slots: the whole run must be rejected, leaving no stranded
	// partial behind.
	toolarge := testPayload(t, ChunkLimit+16)
	if rc := publishFrame(toolarge); rc != 0 {
		t.Fatalf("run past the entry bound must report queue full: rc=%d", rc)
	}

	// The rejected run consumed nothing: the next frame crosses untouched.
	recovered := []byte(`{"type":"infra.state","snapshot":{"status":"ready"}}`)
	if rc := publishFrame(recovered); rc != 1 {
		t.Fatalf("frame after rejected run was refused: rc=%d", rc)
	}

	frames := drainAll(t, h)
	if len(frames) != QueueFrameCap {
		t.Fatalf("expected %d intact frames, got %d", QueueFrameCap, len(frames))
	}
	for i, frame := range frames[:QueueFrameCap-1] {
		if len(frame) != 1 || frame[0] != byte(i) {
			t.Fatalf("filler frame %d corrupted: %v", i, frame)
		}
	}
	tail := frames[QueueFrameCap-1]
	if !bytes.Equal(tail, recovered) {
		t.Fatalf("frame after the rejected run was corrupted: %q", tail)
	}
	if len(drainAll(t, h)) != 0 {
		t.Fatal("partial chunk run leaked frames into the queue")
	}
	r := h.Rejections()
	if r.QueueFull != before.QueueFull+1 || r.Oversized != before.Oversized {
		t.Fatalf("rejected run must count exactly one queue-full drop: %+v", r)
	}
}

// The production shape is one producer (the MoonBit scheduler thread) racing
// one consumer (the pump) plus independent counter readers (Close). Frames
// must arrive whole, ordered and byte-exact while that race runs.
func TestTransportProducerConsumerRace(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if got := drainAll(t, h); len(got) != 0 {
		t.Fatalf("queue was not empty at start: %d frame(s)", len(got))
	}

	// 90 one-chunk frames + 10 two-chunk frames: 110 chunks, and the byte
	// total stays inside the bounded queue, so a correct transport drops
	// nothing. With a 1 MiB chunk the two-chunk frames need the queue's
	// timed wait; that path is exactly what races here.
	frames := make([][]byte, 0, 100)
	for i := 0; i < 90; i++ {
		frames = append(frames, testPayload(t, 64<<10))
	}
	for i := 0; i < 10; i++ {
		frames = append(frames, testPayload(t, ChunkLimit+1024))
	}

	received := make([][]byte, 0, len(frames))
	var mu sync.Mutex
	consumed := make(chan struct{})
	go func() { // consumer: the pump side
		defer close(consumed)
		for {
			frame, err := h.Poll()
			if err != nil {
				t.Errorf("consumer poll: %v", err)
				return
			}
			if frame == nil {
				mu.Lock()
				done := len(received) == len(frames)
				mu.Unlock()
				if done {
					return
				}
				time.Sleep(time.Millisecond)
				continue
			}
			mu.Lock()
			received = append(received, frame)
			mu.Unlock()
		}
	}()
	stop := make(chan struct{})
	go func() { // counter readers: the Close side
		defer close(stop)
		for {
			select {
			case <-consumed:
				return
			default:
				_ = h.Rejections()
				_ = h.DroppedEvents()
			}
		}
	}()
	for _, frame := range frames {
		if rc := publishFrame(frame); rc != 1 {
			t.Fatalf("producer publish rejected under race: rc=%d", rc)
		}
		time.Sleep(500 * time.Microsecond) // let the consumer race the producer
	}
	<-consumed
	<-stop

	mu.Lock()
	defer mu.Unlock()
	if len(received) != len(frames) {
		t.Fatalf("lost frames under race: got %d, want %d (rejections %+v)", len(received), len(frames), h.Rejections())
	}
	for i := range frames {
		if !bytes.Equal(frames[i], received[i]) {
			t.Fatalf("frame %d corrupted under race: got %d bytes", i, len(received[i]))
		}
	}
	assertQuiet(t, h, before)
}

// Transient count pressure must wait for the independent consumer instead of
// rejecting a legitimate burst and killing its Harness.
func TestFullQueueWaitsForConsumer(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	for i := 0; i < QueueFrameCap; i++ {
		if publishFrame([]byte("x")) != 1 {
			t.Fatal("fill failed")
		}
	}
	done := make(chan int, 1)
	go func() { done <- publishFrame(testPayload(t, 300000)) }()
	select {
	case <-done:
		t.Fatal("full queue did not wait")
	case <-time.After(20 * time.Millisecond):
	}
	for i := 0; i < 2; i++ {
		if _, err := h.Poll(); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case rc := <-done:
		if rc != 1 {
			t.Fatalf("waited publish rc=%d", rc)
		}
	case <-time.After(time.Second):
		t.Fatal("publisher not woken")
	}
	frames := drainAll(t, h)
	if len(frames) != QueueFrameCap-1 || len(frames[len(frames)-1]) != 300000 {
		t.Fatal("burst lost a frame")
	}
	assertQuiet(t, h, before)
}

func TestByteBudgetWaitsForConsumer(t *testing.T) {
	h := transportUnderTest()
	before := snapshotRejections(t, h)
	if len(drainAll(t, h)) != 0 {
		t.Fatal("nonempty queue")
	}
	frame := testPayload(t, FrameLimit)
	for i := 0; i < QueueByteCap/FrameLimit; i++ {
		if publishFrame(frame) != 1 {
			t.Fatal("fill failed")
		}
	}
	done := make(chan int, 1)
	go func() { done <- publishFrame(frame) }()
	select {
	case <-done:
		t.Fatal("byte budget did not wait")
	case <-time.After(20 * time.Millisecond):
	}
	first, err := h.Poll()
	if err != nil || !bytes.Equal(first, frame) {
		t.Fatalf("drain first: %v", err)
	}
	select {
	case rc := <-done:
		if rc != 1 {
			t.Fatalf("byte wait rc=%d", rc)
		}
	case <-time.After(time.Second):
		t.Fatal("byte wait did not wake")
	}
	rest := drainAll(t, h)
	if len(rest) != QueueByteCap/FrameLimit {
		t.Fatalf("lost frame: %d", len(rest))
	}
	for _, f := range rest {
		if !bytes.Equal(f, frame) {
			t.Fatal("corrupted byte-pressure frame")
		}
	}
	assertQuiet(t, h, before)
}
