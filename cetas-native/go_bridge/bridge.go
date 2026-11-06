package bridge

/*
#cgo darwin LDFLAGS: -L${SRCDIR}/lib -lcetas_moon
#cgo linux LDFLAGS: -L${SRCDIR}/lib -lcetas_moon -lpthread -lm -ldl
#include <stdint.h>
void cetas_host_boot(void);
int32_t cetas_host_infra_run(void);
int32_t cetas_host_send(int32_t);
int32_t cetas_host_poll_event(uint8_t*, int32_t, int32_t*);
int32_t cetas_host_event_drops(void);
void cetas_host_rejections(int32_t*, int32_t*, int32_t*, int32_t*);
void cetas_host_rejection_context(int32_t*);
int32_t cetas_host_submit_harness(const uint8_t*, int32_t);
int32_t cetas_bridge_publish(const uint8_t*, int32_t);
*/
import "C"
import (
	"errors"
	"fmt"
	"runtime"
	"sync"
)

var (
	once      sync.Once
	moonCalls sync.Mutex
)

func initialize() { once.Do(func() { C.cetas_host_boot() }) }

// Verified bounded-transport limits, mirrored by go_bridge/host.c.
const (
	// ChunkLimit is the wire bound for one queued EventHub chunk.
	ChunkLimit = 262144 // 256 KiB
	// FrameLimit is the largest logical frame the native side accepts and
	// Poll reassembles from chunks.
	FrameLimit = 4194304 // 4 MiB = 16 chunks
	// QueueFrameCap is the native event queue's entry bound.
	QueueFrameCap = 256
	// QueueByteCap is the native event queue's total byte bound.
	QueueByteCap = 16777216 // 16 MiB
)

// chunk framing flags returned through cetas_host_poll_event.
const (
	chunkStart = 1
	chunkEnd   = 2
)

type Infra struct{}

func NewInfra() *Infra { initialize(); return &Infra{} }

// Run must execute on a background goroutine and owns the MoonBit runtime
// for its entire lifetime. Only C queues can be used while it runs.
func (h *Infra) Run() int {
	moonCalls.Lock()
	defer moonCalls.Unlock()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	return int(C.cetas_host_infra_run())
}

var ErrQueueFull = errors.New("infra command queue full")
var ErrInvalidCommand = errors.New("invalid infra command")

const (
	CommandState int32 = 1
	CommandPing  int32 = 2
	CommandStop  int32 = 9
)

func (h *Infra) Send(code int32) error {
	switch int(C.cetas_host_send(C.int32_t(code))) {
	case 1:
		return nil
	case 0:
		return ErrQueueFull
	default:
		return ErrInvalidCommand
	}
}

// Rejections splits the native drop counter into exact causes, so a lost
// frame is never reported as "oversized or queue full" again.
type Rejections struct {
	Allocation int32 // native allocation failure, never mislabeled queue full
	Oversized  int32 // a publish larger than FrameLimit
	QueueFull  int32 // no slot or byte budget left in the bounded queue
	Invalid    int32 // a null or empty publish from the runtime
}

// Total is every rejection; it always matches DroppedEvents.
func (r Rejections) Total() int32 { return r.Oversized + r.QueueFull + r.Invalid + r.Allocation }

// Add sums two cumulative rejection counts.
func (r Rejections) Add(other Rejections) Rejections {
	return Rejections{
		Oversized:  r.Oversized + other.Oversized,
		Allocation: r.Allocation + other.Allocation,
		QueueFull:  r.QueueFull + other.QueueFull,
		Invalid:    r.Invalid + other.Invalid,
	}
}

func (h *Infra) Rejections() Rejections {
	var oversized, full, invalid, allocation C.int32_t
	C.cetas_host_rejections(&oversized, &full, &invalid, &allocation)
	return Rejections{
		Oversized:  int32(oversized),
		Allocation: int32(allocation),
		QueueFull:  int32(full),
		Invalid:    int32(invalid),
	}
}

// pollChunk copies one native chunk out of the queue. On an undersized
// scratch buffer the chunk stays queued and is re-read at exact size.
func (h *Infra) pollChunk(scratch []byte) ([]byte, int32, error) {
	var flags C.int32_t
	n := int(C.cetas_host_poll_event((*C.uint8_t)(&scratch[0]), C.int32_t(len(scratch)), &flags))
	if n == 0 {
		return nil, 0, nil
	}
	if n > 0 {
		return append([]byte(nil), scratch[:n]...), int32(flags), nil
	}
	required := -n
	if required <= 0 || required > ChunkLimit {
		return nil, 0, errors.New("native EventHub chunk needs a buffer outside the 256 KiB chunk bound")
	}
	payload := make([]byte, required)
	m := int(C.cetas_host_poll_event((*C.uint8_t)(&payload[0]), C.int32_t(len(payload)), &flags))
	if m != required {
		return nil, 0, errors.New("native EventHub chunk size changed between probe and read")
	}
	return payload, int32(flags), nil
}

// Poll returns the next complete EventHub frame. The native queue stores
// 256 KiB chunks; a logical frame larger than one chunk arrives as a
// CHUNK_START..CHUNK_END run and is reassembled here. Memory stays bounded:
// at most FrameLimit bytes are ever buffered. Native admission is
// all-or-nothing, so incomplete runs are protocol errors, never silently
// discarded or combined with a later frame.
func (h *Infra) Poll() ([]byte, error) {
	var scratch [16384]byte
	var frame []byte
	started := false
	for {
		chunk, flags, err := h.pollChunk(scratch[:])
		if err != nil {
			return nil, err
		}
		if len(chunk) == 0 {
			if started {
				return nil, errors.New("native EventHub incomplete chunk run")
			}
			return nil, nil
		}
		if flags&chunkStart != 0 {
			if started {
				return nil, errors.New("native EventHub chunk run restarted before completion")
			}
			started = true
		} else if !started {
			return nil, errors.New("native EventHub orphan continuation chunk")
		}
		if len(frame)+len(chunk) > FrameLimit {
			return nil, errors.New("native EventHub reassembled frame exceeds the 4 MiB frame limit")
		}
		frame = append(frame, chunk...)
		if flags&chunkEnd != 0 {
			return frame, nil
		}
	}
}

func (h *Infra) DroppedEvents() int { return int(C.cetas_host_event_drops()) }

// publish enqueues one EventHub frame exactly the way the MoonBit runtime
// does, so the C chunk framing is testable without booting the runtime.
// A nil or empty frame is handed through so the native Invalid rejection
// path stays reachable.
func publish(b []byte) int {
	if len(b) == 0 {
		return int(C.cetas_bridge_publish(nil, 0))
	}
	return int(C.cetas_bridge_publish((*C.uint8_t)(&b[0]), C.int32_t(len(b))))
}

var ErrHarnessTooLarge = errors.New("harness command exceeds 256 KiB")

func (h *Infra) Submit(request []byte) error {
	if len(request) == 0 || len(request) > 262144 {
		return ErrHarnessTooLarge
	}
	switch int(C.cetas_host_submit_harness((*C.uint8_t)(&request[0]), C.int32_t(len(request)))) {
	case 1:
		return nil
	case 0:
		return ErrQueueFull
	default:
		return ErrInvalidCommand
	}
}

// RejectionContext contains dimensions and exact queue limits, never event data.
func (*Infra) RejectionContext() string {
	var v [5]C.int32_t
	C.cetas_host_rejection_context(&v[0])
	return fmt.Sprintf("last_length=%d queued_chunks=%d queued_bytes=%d count_timeouts=%d byte_timeouts=%d", v[0], v[1], v[2], v[3], v[4])
}
