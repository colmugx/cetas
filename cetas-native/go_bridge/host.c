#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
extern void moonbit_runtime_init(int argc, char **argv);
extern void moonbit_init(void);
extern int32_t cetas_infra_run(void);
void cetas_host_boot(void) { moonbit_runtime_init(0, NULL); moonbit_init(); }
int32_t cetas_host_infra_run(void) { return cetas_infra_run(); }

/* Readiness channels replace fixed-interval polling on both sides.
   Each channel is one non-blocking pipe. A producer writes a single byte
   *after* the queues below made its data visible; the byte means only "the
   queue may hold new data", so the mutex-protected queue stays the single
   source of truth and a coalesced or EAGAIN-dropped byte can never lose a
   frame. Exactly one owner waits on each read end:
     - cmd_wake[0]   -> the MoonBit async scheduler (RawFd; it owns the
                        descriptor and closes it when its loop shuts down)
     - event_wake[0] -> the Go event pump (blocking poll, C-owned)
   Both write ends are C-owned for the process lifetime and never closed, so a
   producer can neither block on a full pipe nor signal a broken one. Closing
   order is therefore: the scheduler may close cmd_wake[0] at shutdown, and
   every other end lives until the process exits.

   A channel that cannot be created is fully closed and its stage/errno is
   recorded, never left half-initialised: a blocking end registered in the
   async event loop (or a blocking write end handed to producers) would hang a
   live thread. Both sides read that reason and report it instead of guessing. */
enum {
    WAKE_OK = 0,
    WAKE_PIPE_FAILED = 1,
    WAKE_FCNTL_FAILED = 2,
    WAKE_DUP_FAILED = 3,
    WAKE_TEST_INJECTED = 4
};
static int cmd_wake[2] = { -1, -1 };
static int event_wake[2] = { -1, -1 };
static int cmd_wake_hold = -1;
/* Protected by lock after wake_channels() initialization. Once transferred,
   even diagnostic test seams must not probe/read the recycled fd number. */
static int cmd_wake_transferred;
static int32_t cmd_wake_stage = WAKE_OK, cmd_wake_errno, event_wake_stage = WAKE_OK, event_wake_errno;
static pthread_once_t wake_once = PTHREAD_ONCE_INIT;

/* Close whatever a partial channel opened and record exactly why it failed. */
static int wake_fail(int fds[2], int32_t *stage, int32_t *saved_errno, int32_t why) {
    int saved = errno;
    for (int i = 0; i < 2; i++) {
        if (fds[i] >= 0) { close(fds[i]); fds[i] = -1; }
    }
    *stage = why;
    *saved_errno = saved;
    return -1;
}

static int make_wake_pipe(int fds[2], int32_t *stage, int32_t *saved_errno) {
    fds[0] = -1;
    fds[1] = -1;
    *stage = WAKE_OK;
    *saved_errno = 0;
    if (pipe(fds) != 0) return wake_fail(fds, stage, saved_errno, WAKE_PIPE_FAILED);
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(fds[i], F_GETFL, 0);
        if (flags < 0 || fcntl(fds[i], F_SETFL, flags | O_NONBLOCK) < 0) {
            return wake_fail(fds, stage, saved_errno, WAKE_FCNTL_FAILED);
        }
        int fdflags = fcntl(fds[i], F_GETFD, 0);
        if (fdflags < 0 || fcntl(fds[i], F_SETFD, fdflags | FD_CLOEXEC) < 0) {
            return wake_fail(fds, stage, saved_errno, WAKE_FCNTL_FAILED);
        }
    }
    return 0;
}

static void wake_channels_init(void) {
    /* Transport-test fault injection: the only way to exercise these failure
       paths, since a healthy process cannot fail them on demand. Inert unless
       the transport's own subprocess test sets it. */
    if (getenv("CETAS_NATIVE_TEST_FORCE_COMMAND_WAKE_FAILURE")) {
        cmd_wake_stage = WAKE_TEST_INJECTED;
    } else if (make_wake_pipe(cmd_wake, &cmd_wake_stage, &cmd_wake_errno) == 0) {
        /* The scheduler owns cmd_wake[0] and closes it when its async event
           loop shuts down. Hold our own duplicate so a late producer write
           degrades to EAGAIN on a full pipe instead of EPIPE/SIGPIPE; this
           duplicate is never read and lives for the process lifetime. Without
           the guard the channel is refused outright rather than run unsafely. */
        cmd_wake_hold = fcntl(cmd_wake[0], F_DUPFD_CLOEXEC, 0);
        if (cmd_wake_hold < 0) {
            wake_fail(cmd_wake, &cmd_wake_stage, &cmd_wake_errno, WAKE_DUP_FAILED);
        }
    }
    if (getenv("CETAS_NATIVE_TEST_FORCE_EVENT_WAKE_FAILURE")) {
        event_wake_stage = WAKE_TEST_INJECTED;
    } else {
        make_wake_pipe(event_wake, &event_wake_stage, &event_wake_errno);
    }
}

static void wake_channels(void) { pthread_once(&wake_once, wake_channels_init); }

/* Never block a producer on the notification pipe: a full pipe already holds
   an unconsumed wakeup, and the queue it announces is still authoritative. */
static void wake_signal(int fd) {
    if (fd < 0) return;
    uint8_t byte = 1;
    ssize_t written;
    do { written = write(fd, &byte, 1); } while (written < 0 && errno == EINTR);
}

enum {
    COMMAND_CAP = 64,
    EVENT_CAP = 256,
    EVENT_CHUNK_MAX = 262144,  /* 256 KiB bounded chunk on the wire */
    EVENT_FRAME_MAX = 4194304, /* 4 MiB reassembled logical frame bound */
    EVENT_TOTAL_MAX = 16777216, /* 16 MiB bounded queue */
    EVENT_RUN_MAX = EVENT_FRAME_MAX / EVENT_CHUNK_MAX /* chunks per run */
};
enum { CHUNK_START = 1, CHUNK_END = 2 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t cmds[COMMAND_CAP], ch, cn;
static struct { int32_t len; uint8_t flags; uint8_t *data; } events[EVENT_CAP];
static int32_t eh, en, event_bytes;
/* Exact rejection bookkeeping; drops is always their total. */
static int32_t drops, oversize_rejects, full_rejects, invalid_rejects, allocation_rejects;
static pthread_cond_t event_space = PTHREAD_COND_INITIALIZER;

static int32_t last_length, last_chunks, last_bytes, count_timeouts, byte_timeouts;
static void rejection_context(int32_t len) {
    last_length = len; last_chunks = en; last_bytes = event_bytes;
}
void cetas_host_rejection_context(int32_t *out) {
    pthread_mutex_lock(&lock);
    out[0] = last_length; out[1] = last_chunks; out[2] = last_bytes;
    out[3] = count_timeouts; out[4] = byte_timeouts;
    pthread_mutex_unlock(&lock);
}
static void count_reject(int32_t *kind, int32_t len) {
    pthread_mutex_lock(&lock);
    drops++;
    (*kind)++;
    rejection_context(len);
    pthread_mutex_unlock(&lock);
}

int32_t cetas_host_send(int32_t cmd) {
    if (cmd != 1 && cmd != 2 && cmd != 9) return -1;
    wake_channels();
    pthread_mutex_lock(&lock);
    if (cn == COMMAND_CAP) { pthread_mutex_unlock(&lock); return 0; }
    cmds[(ch + cn) % COMMAND_CAP] = cmd;
    cn++;
    pthread_mutex_unlock(&lock);
    wake_signal(cmd_wake[1]);
    return 1;
}

int32_t cetas_bridge_next_command(void) {
    pthread_mutex_lock(&lock);
    int32_t code = 0;
    if (cn) { code = cmds[ch]; ch = (ch + 1) % COMMAND_CAP; cn--; }
    pthread_mutex_unlock(&lock);
    return code;
}

/* Deep-copy and bound memory; never retain a MoonBit or Go pointer.
   A logical frame up to EVENT_FRAME_MAX crosses as a run of consecutive
   EVENT_CHUNK_MAX-bounded chunks marked CHUNK_START/CHUNK_END, so a large
   legitimate snapshot is delivered instead of dropped whole. Admission is
   all-or-nothing: a run that does not fit the bounded queue is rejected
   whole (counted under full rejections), so the reader never observes a
   partial run and no frame can be corrupted by a lost tail. */
int32_t cetas_bridge_publish(const uint8_t *src, int32_t len) {
    wake_channels();
    if (!src || len <= 0) { count_reject(&invalid_rejects, len); wake_signal(event_wake[1]); return -1; }
    if (len > EVENT_FRAME_MAX) { count_reject(&oversize_rejects, len); wake_signal(event_wake[1]); return -1; }
    int32_t chunks = (len + EVENT_CHUNK_MAX - 1) / EVENT_CHUNK_MAX;
    if (chunks > EVENT_RUN_MAX) { count_reject(&oversize_rejects, len); wake_signal(event_wake[1]); return -1; }
    uint8_t *bufs[EVENT_RUN_MAX];
    int32_t off = 0;
    for (int32_t i = 0; i < chunks; i++) {
        int32_t clen = len - off > EVENT_CHUNK_MAX ? EVENT_CHUNK_MAX : len - off;
        bufs[i] = (uint8_t *)malloc((size_t)clen);
        if (!bufs[i]) {
            for (int32_t j = 0; j < i; j++) free(bufs[j]);
            /* The run was never announced, so nothing is left to discard. */
            count_reject(&allocation_rejects, len);
            wake_signal(event_wake[1]);
            return -1;
        }
        memcpy(bufs[i], src + off, (size_t)clen);
        off += clen;
    }
    pthread_mutex_lock(&lock);
    // Admit a complete run, waiting for the independent Go consumer to
    // release bounded space. Never expose a partial run or silently lose a burst.
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 2;
    while (chunks > EVENT_CAP - en || len > EVENT_TOTAL_MAX - event_bytes) {
        int rc = pthread_cond_timedwait(&event_space, &lock, &deadline);
        if (rc != 0 && (chunks > EVENT_CAP - en || len > EVENT_TOTAL_MAX - event_bytes)) {
            drops++;
            full_rejects++;
            if (chunks > EVENT_CAP - en) count_timeouts++;
            if (len > EVENT_TOTAL_MAX - event_bytes) byte_timeouts++;
            rejection_context(len);
            pthread_mutex_unlock(&lock);
            for (int32_t i = 0; i < chunks; i++) free(bufs[i]);
            /* Delivery was lost: the consumer must wake and report it. */
            wake_signal(event_wake[1]);
            return 0;
        }
    }
    for (int32_t i = 0; i < chunks; i++) {
        int32_t clen = len - (i * EVENT_CHUNK_MAX) > EVENT_CHUNK_MAX
            ? EVENT_CHUNK_MAX : len - (i * EVENT_CHUNK_MAX);
        int32_t pos = (eh + en) % EVENT_CAP;
        events[pos].len = clen;
        events[pos].flags = (uint8_t)((i == 0 ? CHUNK_START : 0) |
                                      (i == chunks - 1 ? CHUNK_END : 0));
        events[pos].data = bufs[i];
        en++;
        event_bytes += clen;
    }
    pthread_mutex_unlock(&lock);
    /* Queue first, notification second: a wakeup is never lost, and the queue
       is what the consumer re-reads. */
    wake_signal(event_wake[1]);
    return 1;
}

/* On undersized buffer, return -required_size without consuming the chunk.
   *flags receives CHUNK_START/CHUNK_END so Go can reassemble chunked frames. */
int32_t cetas_host_poll_event(uint8_t *dst, int32_t capacity, int32_t *flags) {
    if (!dst || capacity <= 0) return -1;
    pthread_mutex_lock(&lock);
    if (!en) { pthread_mutex_unlock(&lock); return 0; }
    int32_t len = events[eh].len;
    if (flags) *flags = events[eh].flags;
    if (len > capacity) { pthread_mutex_unlock(&lock); return -len; }
    memcpy(dst, events[eh].data, (size_t)len);
    free(events[eh].data);
    events[eh].data = NULL;
    events[eh].len = 0;
    events[eh].flags = 0;
    eh = (eh + 1) % EVENT_CAP;
    en--;
    event_bytes -= len;
    pthread_cond_broadcast(&event_space);
    pthread_mutex_unlock(&lock);
    return len;
}

int32_t cetas_host_event_drops(void) {
    pthread_mutex_lock(&lock);
    int32_t n = drops;
    pthread_mutex_unlock(&lock);
    return n;
}

/* Split drop diagnostics: each rejection is counted under its exact cause. */
void cetas_host_rejections(int32_t *oversized, int32_t *full, int32_t *invalid, int32_t *allocation) {
    pthread_mutex_lock(&lock);
    if (oversized) *oversized = oversize_rejects;
    if (full) *full = full_rejects;
    if (invalid) *invalid = invalid_rejects;
    if (allocation) *allocation = allocation_rejects;
    pthread_mutex_unlock(&lock);
}

/* Harness request FIFO: copied bytes, no shared Go/MoonBit memory. */
enum { HARNESS_CAP = 64, HARNESS_BYTES = 262144 };
static struct {
    int32_t len;
    uint8_t bytes[HARNESS_BYTES];
} harness_requests[HARNESS_CAP];
static int32_t h_head, h_size;

int32_t cetas_host_submit_harness(const uint8_t *src, int32_t len) {
    if (!src || len<=0 || len>HARNESS_BYTES) return -1;
    wake_channels();
    pthread_mutex_lock(&lock);
    if (h_size==HARNESS_CAP) {pthread_mutex_unlock(&lock);return 0;}
    int32_t index=(h_head+h_size)%HARNESS_CAP;
    harness_requests[index].len=len;
    memcpy(harness_requests[index].bytes,src,(size_t)len);
    h_size++;
    pthread_mutex_unlock(&lock);
    /* Queue first, then ring the scheduler's doorbell. */
    wake_signal(cmd_wake[1]);
    return 1;
}

int32_t cetas_bridge_next_harness(uint8_t *dst,int32_t cap) {
    if (!dst || cap<=0) return -1;
    pthread_mutex_lock(&lock);
    if (!h_size) {pthread_mutex_unlock(&lock);return 0;}
    int32_t len=harness_requests[h_head].len;
    if (cap<len) {pthread_mutex_unlock(&lock);return -len;}
    memcpy(dst,harness_requests[h_head].bytes,(size_t)len);
    h_head=(h_head+1)%HARNESS_CAP;
    h_size--;
    pthread_mutex_unlock(&lock);
    return len;
}

/* Command/request readiness: the read end the MoonBit async scheduler owns.
   Ownership of this descriptor transfers to that scheduler, which is its only
   reader and closes it; C never touches the read end again. Returns -1 when
   the channel could not be created; the scheduler reports the stage below and
   degrades to bounded polling. */
int32_t cetas_bridge_command_fd(void) {
    wake_channels();
    pthread_mutex_lock(&lock);
    int fd = cmd_wake_transferred ? -1 : cmd_wake[0];
    if (fd >= 0) cmd_wake_transferred = 1;
    pthread_mutex_unlock(&lock);
    return fd;
}

/* Exact command-channel failure stage: WAKE_* above, plus the errno that
   caused it. The scheduler turns this into a named diagnostic instead of
   hiding the degradation. */
int32_t cetas_bridge_command_wake_stage(void) {
    wake_channels();
    return cmd_wake_stage;
}

/* Erroneous errno of the command-channel failure, 0 when none applies. */
int32_t cetas_bridge_command_wake_errno(void) {
    wake_channels();
    return cmd_wake_errno;
}

/* Same pair for the event channel, read by the Go pump when it cannot wait. */
int32_t cetas_host_event_wake_stage(void) {
    wake_channels();
    return event_wake_stage;
}

/* Erroneous errno of the event-channel failure, 0 when none applies. */
int32_t cetas_host_event_wake_errno(void) {
    wake_channels();
    return event_wake_errno;
}

/* Block until a producer signalled new event data, then consume exactly one
   coalesced notification byte. The Go pump is the only caller, so this never
   contends for the read end. -1 reports an unusable channel; the pump then
   reads its stage and errno above and fails with that reason. */
int32_t cetas_host_wait_event(void) {
    wake_channels();
    if (event_wake[0] < 0) return -1;
    struct pollfd ready;
    ready.fd = event_wake[0];
    ready.events = POLLIN;
    ready.revents = 0;
    for (;;) {
        int rc = poll(&ready, 1, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        break;
    }
    uint8_t byte;
    ssize_t got;
    do { got = read(event_wake[0], &byte, 1); } while (got < 0 && errno == EINTR);
    return 1;
}

/* Host doorbell: lets the Go pump re-read state published outside the queue
   (rejection counters, scheduler exit) without a polling tick. -1 means the
   channel is unusable, which the Go pump reports with the stage above. */
int32_t cetas_host_wake(void) {
    wake_channels();
    if (event_wake[0] < 0 || event_wake[1] < 0) return -1;
    wake_signal(event_wake[1]);
    return 1;
}

/* Non-blocking drain of one pending notification byte. Only the transport's
   own tests use it, to tell a stale wakeup from a fresh one; the pump never
   needs it because it re-reads the queue after every wait. */
int32_t cetas_bridge_read_wake(void) {
    wake_channels();
    if (event_wake[0] < 0) return -1;
    uint8_t byte;
    ssize_t got;
    do { got = read(event_wake[0], &byte, 1); } while (got < 0 && errno == EINTR);
    return got == 1 ? 1 : 0;
}

/* Test-only availability before transfer. Never inspect a descriptor owned
   by RawFd: after shutdown the same number may identify an unrelated file. */
int32_t cetas_bridge_command_channel_open(void) {
    wake_channels();
    pthread_mutex_lock(&lock);
    int available = !cmd_wake_transferred && cmd_wake[0] >= 0;
    pthread_mutex_unlock(&lock);
    return available;
}

/* Non-blocking drain of one pending command-channel notification. Transport
   tests use it to prove Send/Submit wake the waiting scheduler. */
int32_t cetas_bridge_read_command_wake(void) {
    wake_channels();
    pthread_mutex_lock(&lock);
    if (cmd_wake_transferred || cmd_wake[0] < 0) {
        pthread_mutex_unlock(&lock);
        return -1;
    }
    uint8_t byte;
    ssize_t got;
    do { got = read(cmd_wake[0], &byte, 1); } while (got < 0 && errno == EINTR);
    pthread_mutex_unlock(&lock);
    return got == 1 ? 1 : 0;
}
