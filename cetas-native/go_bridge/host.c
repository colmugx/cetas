#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
extern void moonbit_runtime_init(int argc, char **argv);
extern void moonbit_init(void);
extern int32_t cetas_infra_run(void);
void cetas_host_boot(void) { moonbit_runtime_init(0, NULL); moonbit_init(); }
int32_t cetas_host_infra_run(void) { return cetas_infra_run(); }

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
    pthread_mutex_lock(&lock);
    if (cn == COMMAND_CAP) { pthread_mutex_unlock(&lock); return 0; }
    cmds[(ch + cn) % COMMAND_CAP] = cmd;
    cn++;
    pthread_mutex_unlock(&lock);
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
    if (!src || len <= 0) { count_reject(&invalid_rejects, len); return -1; }
    if (len > EVENT_FRAME_MAX) { count_reject(&oversize_rejects, len); return -1; }
    int32_t chunks = (len + EVENT_CHUNK_MAX - 1) / EVENT_CHUNK_MAX;
    if (chunks > EVENT_RUN_MAX) { count_reject(&oversize_rejects, len); return -1; }
    uint8_t *bufs[EVENT_RUN_MAX];
    int32_t off = 0;
    for (int32_t i = 0; i < chunks; i++) {
        int32_t clen = len - off > EVENT_CHUNK_MAX ? EVENT_CHUNK_MAX : len - off;
        bufs[i] = (uint8_t *)malloc((size_t)clen);
        if (!bufs[i]) {
            for (int32_t j = 0; j < i; j++) free(bufs[j]);
            /* The run was never announced, so nothing is left to discard. */
            count_reject(&allocation_rejects, len);
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
    pthread_mutex_lock(&lock);
    if (h_size==HARNESS_CAP) {pthread_mutex_unlock(&lock);return 0;}
    int32_t index=(h_head+h_size)%HARNESS_CAP;
    harness_requests[index].len=len;
    memcpy(harness_requests[index].bytes,src,(size_t)len);
    h_size++;
    pthread_mutex_unlock(&lock);
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
