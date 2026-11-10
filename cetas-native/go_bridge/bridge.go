package bridge

/*
#cgo darwin LDFLAGS: -L${SRCDIR}/lib -lcetas_moon
#cgo linux LDFLAGS: -L${SRCDIR}/lib -lcetas_moon -lpthread -lm -ldl
// Link the Windows APIs used by the MoonBit runtime and async backend:
// Winsock, BCrypt, Win32 backtrace, long-path helpers, NT file operations,
// interface enumeration, Schannel credentials and certificate validation.
// MinGW's linker does not add these import libraries automatically.
#cgo windows LDFLAGS: -L${SRCDIR}/lib -lcetas_moon -lws2_32 -lbcrypt -ldbghelp -lpathcch -lntdll -liphlpapi -lsecur32 -lcrypt32
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
int32_t cetas_host_wait_event(void);
int32_t cetas_host_wake(void);
int32_t cetas_host_event_wake_stage(void);
int32_t cetas_host_event_wake_errno(void);
*/
import "C"
import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"
)

var (
	once      sync.Once
	moonCalls sync.Mutex
)

// initialize brings the MoonBit runtime up once. It must run on the same
// locked OS thread that later runs the scheduler: the native runtime and the
// single-owner objects it creates are thread-affine from init onwards.
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
	// HarnessLimit is the native harness request queue's per-request bound.
	HarnessLimit = 262144 // 256 KiB
)

// chunk framing flags returned through cetas_host_poll_event.
const (
	chunkStart = 1
	chunkEnd   = 2
)

// Chunk scratch sizing. The buffer starts small and grows once, to at most
// ChunkLimit, when a chunk is larger than it; idle polls never touch it.
const pollScratch = 16384

type Infra struct {
	// scratch is the pump-owned chunk buffer, reused serially by the single
	// consumer. Frames handed to the caller are copied out of it, so a
	// returned event never aliases memory a later Poll overwrites.
	scratch []byte
	// flags receives the chunk framing bits. It lives here so the address
	// handed to C is a field of an already-heap transport instead of a
	// fresh per-call allocation.
	flags int32
}

func NewInfra() *Infra { return &Infra{} }

// Run must execute on a background goroutine and owns the MoonBit runtime
// for its entire lifetime. Only C queues can be used while it runs.
func (h *Infra) Run() int {
	moonCalls.Lock()
	defer moonCalls.Unlock()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	// Runtime initialization happens here, not in the constructor: the
	// scheduler must start on the very OS thread that initialized it.
	initialize()
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

// pollChunk copies the next native chunk into the transport-owned scratch
// buffer, growing it once when a chunk is larger than the current size. The
// returned slice aliases that scratch buffer until the next call, so Poll
// copies what it returns. An empty queue allocates nothing and never touches
// the buffer, which is what keeps an idle pump allocation-free.
func (h *Infra) pollChunk() ([]byte, int32, error) {
	if h.scratch == nil {
		h.scratch = make([]byte, pollScratch)
	}
	for {
		h.flags = 0
		n := int(C.cetas_host_poll_event(
			(*C.uint8_t)(unsafe.Pointer(&h.scratch[0])),
			C.int32_t(len(h.scratch)),
			(*C.int32_t)(unsafe.Pointer(&h.flags)),
		))
		if n == 0 {
			return nil, 0, nil
		}
		if n > 0 {
			return h.scratch[:n], int32(h.flags), nil
		}
		required := -n
		if required <= 0 || required > ChunkLimit {
			return nil, 0, errors.New("native EventHub chunk needs a buffer outside the 256 KiB chunk bound")
		}
		if required <= len(h.scratch) {
			return nil, 0, errors.New("native EventHub chunk size changed between probe and read")
		}
		// The chunk stayed queued; re-read it at exactly its size. The
		// grown buffer is kept for the rest of the process, so the bigger
		// frames that follow are single reads.
		h.scratch = make([]byte, required)
	}
}

// Poll returns the next complete EventHub frame. The native queue stores
// 256 KiB chunks; a logical frame larger than one chunk arrives as a
// CHUNK_START..CHUNK_END run and is reassembled here. Memory stays bounded:
// at most FrameLimit bytes are ever buffered. Native admission is
// all-or-nothing, so incomplete runs are protocol errors, never silently
// discarded or combined with a later frame.
func (h *Infra) Poll() ([]byte, error) {
	var frame []byte
	started := false
	for {
		chunk, flags, err := h.pollChunk()
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

// wakeStageText names the exact step that failed to build a notification
// channel, so the host never reports a bare "unavailable".
func wakeStageText(stage int32) string {
	switch stage {
	case 1:
		return "pipe() failed"
	case 2:
		return "fcntl() failed setting non-blocking/cloexec"
	case 3:
		return "fcntl(F_DUPFD_CLOEXEC) failed for the producer-write guard"
	case 4:
		return "notification channel disabled by a transport test"
	default:
		return fmt.Sprintf("unknown failure stage %d", stage)
	}
}

// channelError explains a failed wait with the native stage and errno. The
// queue is still authoritative, so this is fatal for the pump: waiting is how
// it learns about new frames, and pretending to wait would silently spin.
func channelError(stage, errno int32) error {
	return fmt.Errorf("native EventHub notification channel unusable: %s (errno=%d)", wakeStageText(stage), errno)
}

// Wait blocks until the native side signals that the bounded event queue may
// hold data, then returns. The signal is only a hint: the queue stays the
// source of truth, so a coalesced wakeup costs one extra Poll and never loses
// a frame. A signal that arrives before Wait is kept by the pipe.
func (h *Infra) Wait() error {
	if int(C.cetas_host_wait_event()) == 1 {
		return nil
	}
	return channelError(int32(C.cetas_host_event_wake_stage()), int32(C.cetas_host_event_wake_errno()))
}

// Wake rings the host's own doorbell so a blocked Wait returns after the
// runtime published state outside the queue (a rejection) or exited.
func (h *Infra) Wake() error {
	if int(C.cetas_host_wake()) == 1 {
		return nil
	}
	return channelError(int32(C.cetas_host_event_wake_stage()), int32(C.cetas_host_event_wake_errno()))
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
	if len(request) == 0 || len(request) > HarnessLimit {
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
