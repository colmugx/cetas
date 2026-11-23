//go:build !windows

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

/* One transport, two platform arms: the queues, chunked framing and rejection
   bookkeeping below are shared, only the wait primitives and the two
   notification channels differ. */
#if defined(_WIN32)
#define CETAS_WINDOWS 1
#include <windows.h>
#else
#define CETAS_WINDOWS 0
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#endif

extern void moonbit_runtime_init(int argc, char **argv);
extern void moonbit_init(void);
extern int32_t cetas_infra_run(void);
void cetas_host_boot(void) { moonbit_runtime_init(0, NULL); moonbit_init(); }

/* Notification is a hint: producers signal after enqueueing, and consumers
   re-read the queues after each wait. POSIX uses nonblocking pipes; the
   scheduler owns the command read descriptor, and a duplicate prevents
   SIGPIPE on late writes. Windows uses auto-reset events, so unconsumed
   notifications coalesce without blocking while the command loop polls. */
enum {
    WAKE_OK = 0,
    WAKE_PIPE_FAILED = 1,
    WAKE_FCNTL_FAILED = 2,
    WAKE_DUP_FAILED = 3,
    WAKE_TEST_INJECTED = 4,
    WAKE_EVENT_FAILED = 5
};

#if CETAS_WINDOWS

typedef SRWLOCK cetas_mutex;
typedef CONDITION_VARIABLE cetas_cond;
#define CETAS_MUTEX_INIT SRWLOCK_INIT
static cetas_cond event_space = CONDITION_VARIABLE_INIT;
static void init_event_space(void) {}

static void cetas_lock(cetas_mutex *m) { AcquireSRWLockExclusive(m); }
static void cetas_unlock(cetas_mutex *m) { ReleaseSRWLockExclusive(m); }
static void cetas_wake_all(cetas_cond *c) { WakeAllConditionVariable(c); }
static uint64_t cetas_now_ms(void) { return (uint64_t)GetTickCount64(); }

/* 0 = signalled, 1 = the deadline passed. */
static int cetas_wait_until(cetas_cond *c, cetas_mutex *m, uint64_t deadline_ms) {
    uint64_t now = cetas_now_ms();
    if (now >= deadline_ms) return 1;
    return SleepConditionVariableSRW(c, m, (DWORD)(deadline_ms - now), 0) ? 0 : 1;
}

#else

typedef pthread_mutex_t cetas_mutex;
typedef pthread_cond_t cetas_cond;
#define CETAS_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#if defined(__APPLE__)
static cetas_cond event_space = PTHREAD_COND_INITIALIZER;
static void init_event_space(void) {}
#else
static cetas_cond event_space;
static int event_space_ready;
static void init_event_space(void) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) != 0) return;
    if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) == 0) {
        event_space_ready = pthread_cond_init(&event_space, &attr) == 0;
    }
    pthread_condattr_destroy(&attr);
}
#endif

static void cetas_lock(cetas_mutex *m) { pthread_mutex_lock(m); }
static void cetas_unlock(cetas_mutex *m) { pthread_mutex_unlock(m); }
static void cetas_wake_all(cetas_cond *c) {
#if !defined(__APPLE__)
    if (!event_space_ready) return;
#endif
    pthread_cond_broadcast(c);
}
static uint64_t cetas_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* 0 = signalled, 1 = the deadline passed. */
static int cetas_wait_until(cetas_cond *c, cetas_mutex *m, uint64_t deadline_ms) {
#if defined(__APPLE__)
    uint64_t now = cetas_now_ms();
    if (now >= deadline_ms) return 1;
    uint64_t remaining = deadline_ms - now;
    struct timespec delay = { (time_t)(remaining / 1000u), (long)((remaining % 1000u) * 1000000u) };
    return pthread_cond_timedwait_relative_np(c, m, &delay) == 0 ? 0 : 1;
#else
    /* If a monotonic condition variable could not be initialized, reject
       a full queue rather than risking an unbounded realtime-clock wait. */
    if (!event_space_ready) return 1;
    struct timespec deadline = { (time_t)(deadline_ms / 1000u), (long)((deadline_ms % 1000u) * 1000000u) };
    return pthread_cond_timedwait(c, m, &deadline) == 0 ? 0 : 1;
#endif
}

#endif

#if CETAS_WINDOWS
static HANDLE cmd_wake_handle = NULL;
static HANDLE event_wake_handle = NULL;
#else
static int cmd_wake[2] = { -1, -1 };
static int event_wake[2] = { -1, -1 };
static int cmd_wake_hold = -1;
/* Protected by lock. Once transferred, even test seams must not probe the
   recycled descriptor number. */
static int cmd_wake_transferred;
#endif
static int32_t cmd_wake_stage = WAKE_OK, cmd_wake_errno, event_wake_stage = WAKE_OK, event_wake_errno;
static void wake_channels_init(void);
static void wake_channels(void);

#if CETAS_WINDOWS

static BOOL CALLBACK wake_once_cb(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once; (void)param; (void)context;
    wake_channels_init();
    return TRUE;
}
static INIT_ONCE wake_once = INIT_ONCE_STATIC_INIT;

static void wake_channels(void) { InitOnceExecuteOnce(&wake_once, wake_once_cb, NULL, NULL); }

static int make_wake_event(HANDLE *handle, int32_t *stage, int32_t *saved_errno) {
    *handle = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!*handle) {
        *saved_errno = (int32_t)GetLastError();
        *stage = WAKE_EVENT_FAILED;
        return -1;
    }
    *stage = WAKE_OK;
    *saved_errno = 0;
    return 0;
}

static int make_command_channel(int32_t *stage, int32_t *saved_errno) {
    return make_wake_event(&cmd_wake_handle, stage, saved_errno);
}

static int make_event_channel(int32_t *stage, int32_t *saved_errno) {
    return make_wake_event(&event_wake_handle, stage, saved_errno);
}

static void hold_command_channel(void) {}

static void wake_signal_command(void) {
    if (cmd_wake_handle) SetEvent(cmd_wake_handle);
}

static void wake_signal_event(void) {
    if (event_wake_handle) SetEvent(event_wake_handle);
}

#else /* POSIX */

static pthread_once_t wake_once = PTHREAD_ONCE_INIT;

static void wake_channels(void) { pthread_once(&wake_once, wake_channels_init); }

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

static int make_command_channel(int32_t *stage, int32_t *saved_errno) {
    return make_wake_pipe(cmd_wake, stage, saved_errno);
}

static int make_event_channel(int32_t *stage, int32_t *saved_errno) {
    return make_wake_pipe(event_wake, stage, saved_errno);
}

/* The scheduler owns cmd_wake[0] and closes it when its async event loop shuts
   down. Hold our own duplicate so a late producer write degrades to EAGAIN on
   a full pipe instead of EPIPE/SIGPIPE; this duplicate is never read and lives
   for the process lifetime. Without the guard the channel is refused outright
   rather than run unsafely. */
static void hold_command_channel(void) {
    cmd_wake_hold = fcntl(cmd_wake[0], F_DUPFD_CLOEXEC, 0);
    if (cmd_wake_hold < 0) {
        wake_fail(cmd_wake, &cmd_wake_stage, &cmd_wake_errno, WAKE_DUP_FAILED);
    }
}

/* Never block a producer on the notification pipe: a full pipe already holds
   an unconsumed wakeup, and the queue it announces is still authoritative. */
static void wake_signal_command(void) {
    if (cmd_wake[1] < 0) return;
    uint8_t byte = 1;
    ssize_t written;
    do { written = write(cmd_wake[1], &byte, 1); } while (written < 0 && errno == EINTR);
}

static void wake_signal_event(void) {
    if (event_wake[1] < 0) return;
    uint8_t byte = 1;
    ssize_t written;
    do { written = write(event_wake[1], &byte, 1); } while (written < 0 && errno == EINTR);
}

#endif

static void wake_channels_init(void) {
    init_event_space();
    /* Transport-test fault injection, compiled only into fault-injection
       builds (CFLAGS -DCETAS_NATIVE_FAULT_INJECTION, set by the Go build tag
       cetas_native_faults). Release builds contain no env-driven way to
       degrade the notification channels. */
#if defined(CETAS_NATIVE_FAULT_INJECTION)
    if (getenv("CETAS_NATIVE_TEST_FORCE_COMMAND_WAKE_FAILURE")) {
        cmd_wake_stage = WAKE_TEST_INJECTED;
    } else if (make_command_channel(&cmd_wake_stage, &cmd_wake_errno) == 0) {
        hold_command_channel();
    }
    if (getenv("CETAS_NATIVE_TEST_FORCE_EVENT_WAKE_FAILURE")) {
        event_wake_stage = WAKE_TEST_INJECTED;
    } else {
        make_event_channel(&event_wake_stage, &event_wake_errno);
    }
#else
    if (make_command_channel(&cmd_wake_stage, &cmd_wake_errno) == 0) {
        hold_command_channel();
    }
    make_event_channel(&event_wake_stage, &event_wake_errno);
#endif
}

enum {
    COMMAND_CAP = 64,
    EVENT_CAP = 256,
    EVENT_CHUNK_MAX = 1048576, /* 1 MiB bounded chunk on the wire */
    EVENT_FRAME_MAX = 4194304, /* 4 MiB reassembled logical frame bound */
    EVENT_TOTAL_MAX = 16777216, /* 16 MiB bounded queue */
    EVENT_RUN_MAX = EVENT_FRAME_MAX / EVENT_CHUNK_MAX /* chunks per run */
};
enum { CHUNK_START = 1, CHUNK_END = 2 };
static cetas_mutex lock = CETAS_MUTEX_INIT;
static int32_t cmds[COMMAND_CAP], ch, cn;
static struct { int32_t len; uint8_t flags; uint8_t *data; } events[EVENT_CAP];
static int32_t eh, en, event_bytes;
/* Exact rejection bookkeeping; drops is always their total. */
static int32_t drops, oversize_rejects, full_rejects, invalid_rejects, allocation_rejects;

static int32_t last_length, last_chunks, last_bytes, count_timeouts, byte_timeouts;
static void rejection_context(int32_t len) {
    last_length = len; last_chunks = en; last_bytes = event_bytes;
}
void cetas_host_rejection_context(int32_t *out) {
    cetas_lock(&lock);
    out[0] = last_length; out[1] = last_chunks; out[2] = last_bytes;
    out[3] = count_timeouts; out[4] = byte_timeouts;
    cetas_unlock(&lock);
}
static void count_reject(int32_t *kind, int32_t len) {
    cetas_lock(&lock);
    drops++;
    (*kind)++;
    rejection_context(len);
    cetas_unlock(&lock);
}

int32_t cetas_host_send(int32_t cmd) {
    if (cmd != 1 && cmd != 2 && cmd != 9) return -1;
    wake_channels();
    cetas_lock(&lock);
    if (cn == COMMAND_CAP) { cetas_unlock(&lock); return 0; }
    cmds[(ch + cn) % COMMAND_CAP] = cmd;
    cn++;
    cetas_unlock(&lock);
    wake_signal_command();
    return 1;
}

int32_t cetas_bridge_next_command(void) {
    cetas_lock(&lock);
    int32_t code = 0;
    if (cn) { code = cmds[ch]; ch = (ch + 1) % COMMAND_CAP; cn--; }
    cetas_unlock(&lock);
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
    if (!src || len <= 0) { count_reject(&invalid_rejects, len); wake_signal_event(); return -1; }
    if (len > EVENT_FRAME_MAX) { count_reject(&oversize_rejects, len); wake_signal_event(); return -1; }
    int32_t chunks = (len + EVENT_CHUNK_MAX - 1) / EVENT_CHUNK_MAX;
    if (chunks > EVENT_RUN_MAX) { count_reject(&oversize_rejects, len); wake_signal_event(); return -1; }
    uint8_t *bufs[EVENT_RUN_MAX];
    int32_t off = 0;
    for (int32_t i = 0; i < chunks; i++) {
        int32_t clen = len - off > EVENT_CHUNK_MAX ? EVENT_CHUNK_MAX : len - off;
        bufs[i] = (uint8_t *)malloc((size_t)clen);
        if (!bufs[i]) {
            for (int32_t j = 0; j < i; j++) free(bufs[j]);
            /* The run was never announced, so nothing is left to discard. */
            count_reject(&allocation_rejects, len);
            wake_signal_event();
            return -1;
        }
        memcpy(bufs[i], src + off, (size_t)clen);
        off += clen;
    }
    cetas_lock(&lock);
    // Admit a complete run, waiting for the independent Go consumer to
    // release bounded space. Never expose a partial run or silently lose a burst.
    uint64_t deadline = cetas_now_ms() + 2000;
    while (chunks > EVENT_CAP - en || len > EVENT_TOTAL_MAX - event_bytes) {
        int rc = cetas_wait_until(&event_space, &lock, deadline);
        if (rc != 0 && (chunks > EVENT_CAP - en || len > EVENT_TOTAL_MAX - event_bytes)) {
            drops++;
            full_rejects++;
            if (chunks > EVENT_CAP - en) count_timeouts++;
            if (len > EVENT_TOTAL_MAX - event_bytes) byte_timeouts++;
            rejection_context(len);
            cetas_unlock(&lock);
            for (int32_t i = 0; i < chunks; i++) free(bufs[i]);
            /* Delivery was lost: the consumer must wake and report it. */
            wake_signal_event();
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
    cetas_unlock(&lock);
    /* Queue first, notification second: a wakeup is never lost, and the queue
       is what the consumer re-reads. */
    wake_signal_event();
    return 1;
}

/* On undersized buffer, return -required_size without consuming the chunk.
   *flags receives CHUNK_START/CHUNK_END so Go can reassemble chunked frames. */
int32_t cetas_host_poll_event(uint8_t *dst, int32_t capacity, int32_t *flags) {
    if (!dst || capacity <= 0) return -1;
    cetas_lock(&lock);
    if (!en) { cetas_unlock(&lock); return 0; }
    int32_t len = events[eh].len;
    if (flags) *flags = events[eh].flags;
    if (len > capacity) { cetas_unlock(&lock); return -len; }
    memcpy(dst, events[eh].data, (size_t)len);
    free(events[eh].data);
    events[eh].data = NULL;
    events[eh].len = 0;
    events[eh].flags = 0;
    eh = (eh + 1) % EVENT_CAP;
    en--;
    event_bytes -= len;
    cetas_wake_all(&event_space);
    cetas_unlock(&lock);
    return len;
}

int32_t cetas_host_event_drops(void) {
    cetas_lock(&lock);
    int32_t n = drops;
    cetas_unlock(&lock);
    return n;
}

/* Split drop diagnostics: each rejection is counted under its exact cause. */
void cetas_host_rejections(int32_t *oversized, int32_t *full, int32_t *invalid, int32_t *allocation) {
    cetas_lock(&lock);
    if (oversized) *oversized = oversize_rejects;
    if (full) *full = full_rejects;
    if (invalid) *invalid = invalid_rejects;
    if (allocation) *allocation = allocation_rejects;
    cetas_unlock(&lock);
}

/* Harness request FIFO: each occupied slot owns its exact-sized byte copy. */
enum { HARNESS_CAP = 64, HARNESS_BYTES = 262144 };
static struct {
    int32_t len;
    uint8_t *data;
} harness_requests[HARNESS_CAP];
static int32_t h_head, h_size;

int32_t cetas_host_submit_harness(const uint8_t *src, int32_t len) {
    if (!src || len <= 0 || len > HARNESS_BYTES) return -1;
    wake_channels();
    cetas_lock(&lock);
    if (h_size == HARNESS_CAP) { cetas_unlock(&lock); return 0; }
    uint8_t *data = (uint8_t *)malloc((size_t)len);
    if (!data) { cetas_unlock(&lock); return -2; }
    memcpy(data, src, (size_t)len);
    int32_t index = (h_head + h_size) % HARNESS_CAP;
    harness_requests[index].len = len;
    harness_requests[index].data = data;
    h_size++;
    cetas_unlock(&lock);
    wake_signal_command();
    return 1;
}

int32_t cetas_bridge_next_harness(uint8_t *dst, int32_t cap) {
    if (!dst || cap <= 0) return -1;
    cetas_lock(&lock);
    if (!h_size) { cetas_unlock(&lock); return 0; }
    int32_t len = harness_requests[h_head].len;
    if (cap < len) { cetas_unlock(&lock); return -len; }
    uint8_t *data = harness_requests[h_head].data;
    harness_requests[h_head].data = NULL;
    harness_requests[h_head].len = 0;
    h_head = (h_head + 1) % HARNESS_CAP;
    h_size--;
    cetas_unlock(&lock);
    memcpy(dst, data, (size_t)len);
    free(data);
    return len;
}

/* Stop can overtake harness requests. Release their owned copies when the
   scheduler exits, including after an unsuccessful boot. */
int32_t cetas_host_infra_run(void) {
    int32_t result = cetas_infra_run();
    cetas_lock(&lock);
    while (h_size) {
        free(harness_requests[h_head].data);
        harness_requests[h_head].data = NULL;
        harness_requests[h_head].len = 0;
        h_head = (h_head + 1) % HARNESS_CAP;
        h_size--;
    }
    cetas_unlock(&lock);
    return result;
}

/* The scheduler owns the transferred POSIX read end. Windows polls instead
   and cannot claim a descriptor. */
int32_t cetas_bridge_command_fd(void) {
#if CETAS_WINDOWS
    return -1;
#else
    wake_channels();
    cetas_lock(&lock);
    int fd = cmd_wake_transferred ? -1 : cmd_wake[0];
    if (fd >= 0) cmd_wake_transferred = 1;
    cetas_unlock(&lock);
    return fd;
#endif
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
#if CETAS_WINDOWS
    if (!event_wake_handle) return -1;
    return WaitForSingleObject(event_wake_handle, INFINITE) == WAIT_OBJECT_0 ? 1 : -1;
#else
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
#endif
}

/* Host doorbell: lets the Go pump re-read state published outside the queue
   (rejection counters, scheduler exit) without a polling tick. -1 means the
   channel is unusable, which the Go pump reports with the stage above. */
int32_t cetas_host_wake(void) {
    wake_channels();
#if CETAS_WINDOWS
    if (!event_wake_handle) return -1;
    return SetEvent(event_wake_handle) ? 1 : -1;
#else
    if (event_wake[0] < 0 || event_wake[1] < 0) return -1;
    wake_signal_event();
    return 1;
#endif
}

/* Non-blocking drain of one pending notification byte. Only the transport's
   own tests use it, to tell a stale wakeup from a fresh one; the pump never
   needs it because it re-reads the queue after every wait. */
int32_t cetas_bridge_read_wake(void) {
    wake_channels();
#if CETAS_WINDOWS
    if (!event_wake_handle) return -1;
    /* A zero-timeout wait consumes an auto-reset event: same "is a wakeup
       pending, and take it" semantics as the byte drain. */
    return WaitForSingleObject(event_wake_handle, 0) == WAIT_OBJECT_0 ? 1 : 0;
#else
    if (event_wake[0] < 0) return -1;
    uint8_t byte;
    ssize_t got;
    do { got = read(event_wake[0], &byte, 1); } while (got < 0 && errno == EINTR);
    return got == 1 ? 1 : 0;
#endif
}

/* Test-only availability before transfer. Never inspect a descriptor owned
   by RawFd: after shutdown the same number may identify an unrelated file. */
int32_t cetas_bridge_command_channel_open(void) {
    wake_channels();
    cetas_lock(&lock);
#if CETAS_WINDOWS
    int available = cmd_wake_handle != NULL;
#else
    int available = !cmd_wake_transferred && cmd_wake[0] >= 0;
#endif
    cetas_unlock(&lock);
    return available;
}

/* Non-blocking consumption of one pending command-channel notification. */
int32_t cetas_bridge_read_command_wake(void) {
    wake_channels();
#if CETAS_WINDOWS
    if (!cmd_wake_handle) return -1;
    return WaitForSingleObject(cmd_wake_handle, 0) == WAIT_OBJECT_0 ? 1 : 0;
#else
    cetas_lock(&lock);
    if (cmd_wake_transferred || cmd_wake[0] < 0) {
        cetas_unlock(&lock);
        return -1;
    }
    uint8_t byte;
    ssize_t got;
    do { got = read(cmd_wake[0], &byte, 1); } while (got < 0 && errno == EINTR);
    cetas_unlock(&lock);
    return got == 1 ? 1 : 0;
#endif
}

/* The native host must use the same allocator contract as its MoonBit
 * archive. CI and release builds set MOONBIT_ALLOCATOR=system, where mi_* is
 * deliberately absent. Mimalloc collection/statistics are opt-in ONLY when
 * host.c and the MoonBit archive were both built for mimalloc, using
 * -DCETAS_USE_MIMALLOC=1 (or MSVC /DCETAS_USE_MIMALLOC=1).
 *
 * Cycle collection remains available with either allocator. System malloc
 * handles freed pages itself; it does not expose mimalloc's collect/stats
 * interface. Never emit unresolved references to mi_* in a system build. */
#include <stdio.h>
extern void moonbit_collect_cycles(void);

#ifdef CETAS_USE_MIMALLOC
#include <stdbool.h>
extern void mi_collect(bool force);
extern void mi_stats_print_out(void (*out)(const char *, void *), void *arg);

static void cetas_stat_to_file(const char *msg, void *arg) {
    fputs(msg, (FILE *)arg);
}
#endif

void cetas_heap_relief(void) {
    moonbit_collect_cycles();
#ifdef CETAS_USE_MIMALLOC
    mi_collect(true);
#endif
}

void cetas_heap_stats_file(const char *path) {
    FILE *out = fopen(path, "w");
    if (out == NULL) {
        return;
    }
#ifdef CETAS_USE_MIMALLOC
    mi_stats_print_out(cetas_stat_to_file, out);
#else
    fputs("allocator: system (mimalloc statistics unavailable)\n", out);
#endif
    fclose(out);
}
