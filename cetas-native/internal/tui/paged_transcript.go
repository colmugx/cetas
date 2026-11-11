package tui

// Native paged replay is the on-demand document for sessions whose journal is
// too large to restore in one reply. It speaks the console's bounded replay
// routes (cetas-console/console/native_replay.mbt) and nothing else:
//
//	transcript_index {session_id, first, limit}
//	    -> {session_id, revision:"size:mtime:ns", total, context,
//	        items:[{index, kind, turnId, callId?, name?, status?, textBytes?,
//	                argsBytes?, resultBytes?}]}
//	transcript_page {session_id, revision, first, limit, max_bytes}
//	    -> {session_id, revision, first, total,
//	        items:[{index, ...transcriptItem, turnId, streaming, *Ref?}],
//	        next: int|null}
//	transcript_source {session_id, revision, index, offset, length}
//	    -> {session_id, revision, index, offset, length, total_bytes,
//	        next: int|null, data}
//
// Contract facts this adapter is built on, taken from native_replay.mbt:
//
//   - `revision` is a STRING (journal size + mtime), never a counter. It is the
//     immutable generation: it changes on every journal write, so replies of a
//     retired generation are dropped and a "stale transcript revision" error
//     re-indexes instead of replaying a different history under old indexes.
//   - `total` is the absolute projected BLOCK total; page `first`/`limit` are in
//     that same block space and every item carries its absolute `index`, so one
//     document block IS one console block. The projection emits reasoning as its
//     own block, and `transcript_index` answers only a bounded light window
//     (REPLAY_INDEX_WINDOW=400) with no `first`/`next`, so there is no
//     full-corpus cover from which a fold offset could be computed. Thinking
//     therefore keeps its existing panel but owns its absolute block, directly
//     above the answer it belongs to, instead of being merged into it.
//   - The index reply carries no `first`/`next`; the adapter only needs
//     `revision`, `total` and `context`, so it probes with `first:0, limit:1`.
//   - Bodies at or below REPLAY_INLINE_BYTES ride inline; a larger payload is a
//     REPLAY_PREVIEW_CHARS preview plus `textRef`/`resultRef`/`argsRef`
//     {index, field, offset, length} where `length` is the whole payload in bytes.
//     The adapter renders the preview, then streams REPLAY_SOURCE_MAX_BYTES-bounded
//     range chunks through `transcript_source` while the block is mounted. A ref
//     names its own payload, so the request passes `field` back instead of letting
//     the console fall back to "auto" (text, or a tool result): a giant `args`
//     payload would otherwise never resolve, and the tool row would render the
//     literal `null` forever.
//   - `revision` arrives on every reply and is the only generation proof there
//     is. It is never a promise that the journal only grew, so resident bodies are
//     dropped on a bump (see adopt) and read again on demand.
//
// model.go owns the model field, so the three method hooks live there. Paste:
//
//	// replay is nil until the first paged reply; nil = classic mode.
//	replay *pagedReplay
//
//	func (m *model) startPagedReplay() tea.Cmd { return m.replay.start(m) }
//	func (m *model) applyPagedReply(r commandResult) (tea.Cmd, bool) {
//		return m.replay.apply(m, r)
//	}
//	func (m *model) ensureTranscriptPages() tea.Cmd { return m.replay.ensure(m) }
//
// Parent obligations, in order:
//
//  1. Allocate once (`m.replay = newPagedReplay()`), and send `startPagedReplay`
//     instead of the `session_transcript` request wherever a replay begins:
//     infra.ready, runtime_state first attach, switch_session/new_session and
//     rewind_apply. `start` resets the document, so a session switch needs
//     nothing else. Classic in-memory hosts keep `restoreTranscript`.
//  2. Route by name BEFORE the generic `{"error":...}` commandResult handling: a
//     stale revision arrives as an error payload and must reach applyPagedReply
//     so the adapter can re-index. A true result consumes `transcript_index`,
//     `transcript_page` and `transcript_source`.
//  3. Call `ensureTranscriptPages` after anything that moves the mounted window
//     (scroll keys, wheel, resize, /find), and once after a page reply if the
//     parent coalesces commands; the adapter is idempotent and returns nil when
//     the window is resident.
//  4. While `m.replay.active()`, read through `m.replay.find(&m, query)` and
//     `m.replay.copyHistory(&m, first, last)` so a match or a copy outside the
//     resident pages is still served (both stream pages; a copy of a released or
//     preview-only range asks for it and reports a retryable status). The search
//     scan also streams every deferred payload in bounded ranges, so a match past
//     REPLAY_PREVIEW_CHARS is found without the body ever becoming resident;
//     `m.replay.cancelScan(&m)` abandons a scan whose query was cleared.
//  5. `m.replay.failed()`/`failureReason()` report a console that refused the
//     routes after repeated errors; say so and fall back to `session_transcript`
//     explicitly instead of silently swapping the source.
//  6. Call `m.replay.refresh(&m)` after something wrote the journal (a settled
//     turn, an idle snapshot, a compaction) so the appended blocks enter the
//     absolute index. Appended blocks open room before the live tail, which keeps
//     its content and its position; the paged bodies above it are re-read, because
//     a revision cannot prove they are still current.
//
// Two console behaviours shape the page write path: a page may re-deliver a block
// it already emitted (a ToolMessage on a later journal line patches a running
// tool item), so an incoming block that supersedes the resident copy upgrades it
// in place; and a refused range read only retires that deferred payload, because
// the preview stays readable and must not stall pagination.
//
// Resident accounting: `r.bytes` counts payload bytes that are really held — the
// previews and inline bodies a page delivered, plus the `transcript_source` ranges
// accumulated so far. A ref's `length` is never charged before its payload exists.
// One exception is deliberate and bounded: a painted (or copy-pinned) payload
// larger than the whole budget still streams to completion, because the only
// alternative is showing its 512-character preview as if it were the body. That
// one oversize working set is released the moment the block scrolls out, and a
// second oversize payload never becomes resident: it keeps its preview and says so
// in the status line instead of pretending to be complete.

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"
	transcriptui "github.com/colmugx/cetas/cetas-native/internal/tui/transcript"
)

const (
	// pagedResidentBudget bounds the payload bytes held in the document. Bodies
	// outside the budget are fetched again when they scroll back in. One painted
	// body larger than the whole budget is allowed as the documented oversize
	// working-set exception (see wantedBody) and is released when it scrolls out.
	pagedResidentBudget = 8 << 20
	// pagedPageLimit is a bounded page; the console trims by max_bytes too and
	// reports the continuation in `next`.
	pagedPageLimit = 32
	// pagedPageMaxBytes asks for the console's default page budget.
	pagedPageMaxBytes = 1 << 20
	// pagedScanPageLimit is the read size of the full-corpus source scan used by
	// search and copy, which never materializes the session.
	pagedScanPageLimit = 256
	// pagedSourceChunkBytes is one `transcript_source` range read. The console
	// caps it at REPLAY_SOURCE_MAX_BYTES (1 MiB).
	pagedSourceChunkBytes = 256 << 10
	// pagedRequestStale bounds how many frames an unanswered request is
	// remembered, so a lost reply cannot wedge the window forever.
	pagedRequestStale = 64
	// pagedIndexProbeLimit asks the index for a single light item: only
	// revision/total/context are needed to size the absolute block space.
	pagedIndexProbeLimit = 1
	// pagedErrorBudget is how many consecutive console errors stall on-demand
	// loading instead of repeating the same failing request every frame.
	pagedErrorBudget = 3
	// pagedScanRestartBudget bounds how often one search may be restarted by a
	// journal write. A session that keeps being rewritten aborts the scan with a
	// visible reason instead of looping forever.
	pagedScanRestartBudget = 2
	// pagedPinLimit bounds how many blocks one synchronous paged copy may keep
	// resident. A copy needs its whole range at once to produce the clipboard
	// text, so an unbounded selection would pin the session instead of paging it;
	// a larger range is refused with an actionable reason (see copyRange).
	pagedPinLimit = 64
)

// pagedRef is one giant-body range descriptor (textRef/resultRef/argsRef).
// `Length` is the whole payload in bytes, `Offset` the first byte that was not
// inlined, and `Field` the payload name the console resolves on
// `transcript_source` ("text", "result" or "args"). A ref is self-describing, so
// the adapter passes the field back instead of guessing it from the block kind.
type pagedRef struct {
	Index  int    `json:"index"`
	Field  string `json:"field"`
	Offset int    `json:"offset"`
	Length int    `json:"length"`
}

// pagedItem is one console transcript block. Unknown fields are ignored and
// optional ones stay zero, so additive schema growth never fails a decode.
type pagedItem struct {
	Index       int             `json:"index"`
	Kind        string          `json:"kind"`
	TurnID      string          `json:"turnId"`
	CallID      string          `json:"callId"`
	Name        string          `json:"name"`
	Status      string          `json:"status"`
	Text        string          `json:"text"`
	Reasoning   string          `json:"reasoning"`
	Arguments   json.RawMessage `json:"args"`
	Result      json.RawMessage `json:"result"`
	Streaming   bool            `json:"streaming"`
	TextRef     *pagedRef       `json:"textRef"`
	ResultRef   *pagedRef       `json:"resultRef"`
	ArgsRef     *pagedRef       `json:"argsRef"`
	TextBytes   int             `json:"textBytes"`
	ArgsBytes   int             `json:"argsBytes"`
	ResultBytes int             `json:"resultBytes"`
}

// partial reports whether the payload a copy reads (the text, or a tool result)
// is still a preview that needs `transcript_source` range reads.
func (item pagedItem) partial() bool {
	return item.TextRef != nil || item.ResultRef != nil
}

// pending reports whether any payload of the block still has to be streamed:
// the text, a tool result, or the call arguments the row displays. A block can
// carry two refs at once (a giant result and giant arguments).
func (item pagedItem) pending() bool {
	return item.partial() || item.ArgsRef != nil
}

// deferredPayload is the next payload of the block to stream, in document order.
// `transcript_source` resolves one field per read, so the fields are read one at
// a time and the completed one is cleared from the item.
func (item pagedItem) deferredPayload() (string, *pagedRef) {
	switch {
	case item.TextRef != nil && item.TextRef.Length > 0:
		return "text", item.TextRef
	case item.ResultRef != nil && item.ResultRef.Length > 0:
		return "result", item.ResultRef
	case item.ArgsRef != nil && item.ArgsRef.Length > 0:
		return "args", item.ArgsRef
	}
	return "", nil
}

// supersedes reports whether a re-delivered block carries newer state than the
// copy already resident. The console patches a tool item when its ToolMessage
// appears on a later journal line, and that line can land in a later page, so a
// page may legitimately re-deliver a block it already emitted.
func (item pagedItem) supersedes(resident pagedItem) bool {
	if item.Kind != resident.Kind {
		return true
	}
	if resident.Status == "running" && item.Status != "" && item.Status != "running" {
		return true
	}
	if resident.pending() && !item.pending() {
		return true
	}
	if len(item.Text) > len(resident.Text) || len(item.Result) > len(resident.Result) {
		return true
	}
	return false
}

// bytes is the body weight this item costs while resident: the payload strings it
// actually holds, and nothing else. A ref is a *promise* of a payload that has not
// been read yet; charging its length here would let an unfetched preview exhaust
// the resident budget and wedge its own range reads (see wantedBody). Only the
// accumulated `transcript_source` bytes of a deferred payload are charged, as they
// arrive, and the preview they replace is released in completeBody.
func (item pagedItem) bytes() int {
	return len(item.Text) + len(item.Reasoning) + len(item.Arguments) + len(item.Result) + len(item.Name) + len(item.CallID) + len(item.Status)
}

// refBytes is how much payload the refs of the block still have to read. It is a
// cost estimate for a copy, which needs whole payloads, never a resident charge.
func (item pagedItem) refBytes() int {
	size := 0
	for _, ref := range []*pagedRef{item.TextRef, item.ResultRef, item.ArgsRef} {
		if ref != nil && ref.Length > 0 {
			size += ref.Length
		}
	}
	return size
}

// pagedByteSize renders a payload size for a status line.
func pagedByteSize(size int) string {
	switch {
	case size >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(size)/(1<<20))
	case size >= 1<<10:
		return fmt.Sprintf("%.1f KiB", float64(size)/(1<<10))
	}
	return fmt.Sprintf("%d B", size)
}

// pagedReply is shared by the index and page answers: unknown fields are
// ignored, absent numbers stay nil, and `error` carries a protocol-level
// failure such as a stale revision.
type pagedReply struct {
	SessionID string            `json:"session_id"`
	Revision  string            `json:"revision"`
	Total     *int              `json:"total"`
	First     *int              `json:"first"`
	Next      *int              `json:"next"`
	Context   json.RawMessage   `json:"context"`
	Items     []json.RawMessage `json:"items"`
	Error     string            `json:"error"`
}

// pagedSourceReply is one bounded byte range of a deferred body.
type pagedSourceReply struct {
	SessionID  string `json:"session_id"`
	Revision   string `json:"revision"`
	Index      *int   `json:"index"`
	Field      string `json:"field"`
	Offset     int    `json:"offset"`
	Length     int    `json:"length"`
	TotalBytes int    `json:"total_bytes"`
	Next       *int   `json:"next"`
	Data       string `json:"data"`
	Error      string `json:"error"`
}

// pagedPage records which bodies one reply brought in. Eviction works on whole
// pages, the unit the console can serve again.
type pagedPage struct {
	first   int
	indices []int
	bytes   int
	used    uint64
}

// pagedBody accumulates a deferred payload for one block through range reads.
type pagedBody struct {
	block    int
	field    string // "text" or "result"
	total    int    // whole payload in bytes, from the ref
	data     []byte
	next     int // next byte offset to request
	inflight bool
	failures int
}

// pagedScan is a full-corpus source read for search. Pages are consumed and
// released instead of becoming resident, and a payload the page only previewed is
// streamed through `transcript_source` in bounded ranges.
type pagedScan struct {
	query      string
	needle     string // lowercase query, ready for searchTranscriptSource
	next       int    // first block of the next page to read
	hits       []transcriptSearchHit
	streams    []*pagedScanStream // deferred payloads of the page in hand
	awaiting   bool               // a page request is outstanding
	unreadable int                // payloads the console refused for this query
	restarts   int                // generations this scan was re-armed across
}

// current is the deferred payload the scan is reading: the head of the queue.
func (scan *pagedScan) current() *pagedScanStream {
	if scan == nil || len(scan.streams) == 0 {
		return nil
	}
	return scan.streams[0]
}

// pagedScanStream reads one deferred payload for the scan. It never holds the
// body: only the current chunk, a needle-sized overlap, and the payload offset up
// to which a match start has already been reported, so a query that spans two
// chunks is found exactly once.
type pagedScanStream struct {
	block    int
	field    string // "text", "result" or "args"
	hidden   bool
	prefix   string // literal prefix the materialized source carries
	total    int    // whole payload in bytes, from the ref
	next     int    // next byte offset to request
	tail     string // overlap kept between chunks
	searched int    // payload offset already searched for a match start
	inflight bool
	issued   uint64 // frame the range read was issued
}

// pagedReplay is the sparse replay document. It holds no session authority:
// session and revision are immutable generation checks, so a late reply can
// never rewrite a newer document.
type pagedReplay struct {
	session  string
	revision string
	indexed  bool
	total    int // absolute projected blocks, and document blocks
	context  json.RawMessage

	resident map[int]pagedItem  // block index -> body
	pages    map[int]*pagedPage // request key -> page record
	bodies   map[int]*pagedBody // block index -> deferred payload
	bytes    int
	clock    uint64
	budget   int

	retired  map[string]bool // revisions already superseded
	inflight map[int]uint64  // request key -> frame the request was issued
	pins     map[int]bool    // blocks the user explicitly asked to read
	scan     *pagedScan
	failures int
	stalled  bool
	reason   string
}

func newPagedReplay() *pagedReplay { return &pagedReplay{} }

func (r *pagedReplay) residentBudget() int {
	if r.budget > 0 {
		return r.budget
	}
	return pagedResidentBudget
}

// reset retires the whole document. A session switch and a wholesale rewind
// both go through here, so no body, page or in-flight request survives them.
func (r *pagedReplay) reset() {
	budget := r.budget
	*r = pagedReplay{budget: budget}
}

// active reports whether the document is driven by pages right now. The classic
// in-memory transcript stays available to hosts that never serve the index.
func (r *pagedReplay) active() bool { return r != nil && r.indexed }

// blockCount is the absolute size of the paged document, excluding live blocks
// appended after it.
func (r *pagedReplay) blockCount() int {
	if r == nil {
		return 0
	}
	return r.total
}

// contextPayload is the light context metadata the index carries; the parent may
// fold it into the surface snapshot without fetching a body.
func (r *pagedReplay) contextPayload() json.RawMessage {
	if r == nil {
		return nil
	}
	return r.context
}

// start (m.startPagedReplay) retires the previous document and asks the console
// for the index probe.
func (r *pagedReplay) start(m *model) tea.Cmd {
	if r == nil || m == nil {
		return nil
	}
	r.reset()
	r.session = m.session
	return r.requestIndex(m)
}

func (r *pagedReplay) requestIndex(m *model) tea.Cmd {
	if m == nil || m.host == nil || r.session == "" {
		return nil
	}
	return requestAs(m.host, "transcript_index", "transcript_index", map[string]any{
		"session_id": r.session,
		"first":      0,
		"limit":      pagedIndexProbeLimit,
	})
}

// apply (m.applyPagedReply) consumes the three replay routes. It reports false
// for any other command so the parent reducer keeps its existing handling.
func (r *pagedReplay) apply(m *model, result commandResult) (tea.Cmd, bool) {
	if r == nil || m == nil {
		return nil, false
	}
	switch result.name {
	case "transcript_index", "transcript_page", "transcript_source":
	default:
		return nil, false
	}
	if result.err != nil {
		r.noteFailure(m, result.name+": "+result.err.Error())
		return nil, true
	}
	if message, sessionID, revision, ok := pagedError(result.payload); ok {
		if sessionID != "" && r.session != "" && sessionID != r.session {
			return nil, true // a reply for a session that is no longer displayed
		}
		if revision != "" && r.revision != "" && revision != r.revision {
			// The journal moved on: every body of the old generation is gone, so
			// re-index instead of replaying a different history under old indexes.
			r.adopt(m, revision)
			return r.requestIndex(m), true
		}
		if result.name == "transcript_source" {
			// A range read can fail for a legitimate reason: a tool block whose
			// result has not been written yet, or a payload the console refuses.
			// That preview stays visible, so it must not stall pagination; a scan
			// reports the payload as unreadable instead of dropping it silently.
			r.failSource(m, message)
			return nil, true
		}
		r.noteFailure(m, result.name+": "+message)
		return nil, true
	}
	switch result.name {
	case "transcript_index":
		return r.applyIndex(m, result.payload), true
	case "transcript_page":
		return r.applyPage(m, result.payload), true
	default:
		return r.applySource(m, result.payload), true
	}
}

// pagedError recognises the console's protocol-level failure envelope.
func pagedError(payload json.RawMessage) (message, sessionID, revision string, ok bool) {
	var reply struct {
		Error     string `json:"error"`
		SessionID string `json:"session_id"`
		Revision  string `json:"revision"`
	}
	if len(payload) == 0 || json.Unmarshal(payload, &reply) != nil || reply.Error == "" {
		return "", "", "", false
	}
	return reply.Error, reply.SessionID, reply.Revision, true
}

// noteFailure keeps one broken route from being retried every frame. The status
// line carries the console's own message; the document itself is untouched.
func (r *pagedReplay) noteFailure(m *model, message string) {
	r.releaseInflight()
	r.failures++
	if r.failures < pagedErrorBudget {
		return
	}
	r.stalled = true
	r.reason = message
	scan := r.scan
	r.scan = nil
	if m != nil {
		m.status = "transcript replay paused: " + message
		if scan != nil {
			// A stalled document cannot read the corpus, so the search must not
			// look like it finished.
			m.status += " (search aborted)"
		}
	}
}

// failed reports that the console refused the replay routes (a non-native host,
// a missing journal, repeated range errors). The parent should say so and fall
// back to the classic `session_transcript` explicitly, never silently.
func (r *pagedReplay) failed() bool { return r != nil && r.stalled }

// failureReason is the console's own message behind failed().
func (r *pagedReplay) failureReason() string {
	if r == nil {
		return ""
	}
	return r.reason
}

// failSource retires the one range read that was in flight. Only a single chunk
// is ever requested per frame, so the failure is attributable; a second failure
// drops the deferred payload and the preview remains on screen. A scan cannot
// keep a preview, so the payload counts as unreadable and the result says so.
func (r *pagedReplay) failSource(m *model, message string) {
	bodyFailed := false
	for block, body := range r.bodies {
		if !body.inflight {
			continue
		}
		body.inflight = false
		body.failures++
		bodyFailed = true
		if body.failures >= 2 {
			r.bytes = max(0, r.bytes-len(body.data))
			delete(r.bodies, block)
		}
	}
	scanFailed := false
	if scan := r.scan; scan != nil {
		if stream := scan.current(); stream != nil && stream.inflight {
			stream.inflight = false
			scan.streams = scan.streams[1:]
			scan.unreadable++
			scanFailed = true
		}
	}
	if m == nil || message == "" {
		return
	}
	switch {
	case scanFailed:
		m.status = "transcript search: block payload unavailable: " + message
	case bodyFailed:
		m.status = "transcript body unavailable: " + message
	}
}

func (r *pagedReplay) releaseInflight() {
	r.inflight = nil
	if r.scan != nil {
		r.scan.awaiting = false
		for _, stream := range r.scan.streams {
			stream.inflight = false
		}
	}
	for _, body := range r.bodies {
		body.inflight = false
	}
}

func decodePagedReply(payload json.RawMessage) (pagedReply, bool) {
	var reply pagedReply
	if len(payload) == 0 || json.Unmarshal(payload, &reply) != nil {
		return pagedReply{}, false
	}
	return reply, true
}

// adopt switches to a newer journal generation. A revision is an opaque
// "<size>:<mtime>:<ns>" string: it proves the journal changed, never that the
// change was append-only. The console exposes no wire-level append proof (an
// index or page reply carries only session_id/revision/total/first/context/items;
// its own "incremental extension" anchor check is internal), so a compaction, a
// rewind or a metadata rewrite can rewrite every block under the same document.
// Resident bodies are therefore unproven: they are dropped and re-read on demand
// instead of being shown under a revision that no longer describes them. Only
// live appends after the paged region keep their content.
func (r *pagedReplay) adopt(m *model, revision string) {
	if r.revision != "" && r.revision != revision {
		r.retire(r.revision)
	}
	r.revision = revision
	scan := r.scan
	r.releaseDeferred()
	r.dropBodies(m)
	r.failures, r.stalled, r.reason = 0, false, ""
	if scan != nil {
		// Block indexes of the retired generation cannot be reused: restart the
		// scan against the new revision rather than merging two histories.
		r.rearmScan(m, scan)
	}
}

// dropBodies releases every resident body and re-materializes the blocks it
// filled, so no text of a retired generation stays on screen while the pages of
// the new one are read again.
func (r *pagedReplay) dropBodies(m *model) {
	blocks := make([]int, 0, len(r.resident))
	for block := range r.resident {
		blocks = append(blocks, block)
	}
	r.resident, r.pages, r.bytes = nil, nil, 0
	if m == nil || len(blocks) == 0 {
		return
	}
	sort.Ints(blocks)
	for _, block := range blocks {
		r.rebuildBlock(m, block) // no resident copy left: clears the block
	}
	m.sortHiddenSources()
	m.refreshTranscript()
}

// rearmScan restarts a running scan against the current generation. The restart
// is bounded: a journal that is rewritten on every page aborts the search with a
// visible reason instead of looping and instead of reporting a truncated scan.
func (r *pagedReplay) rearmScan(m *model, scan *pagedScan) {
	if scan == nil {
		return
	}
	// Decide restart-ness BEFORE resetting: a scan that had consumed nothing
	// of the retired generation is a rebinding, not a restart. Testing the
	// reset values (the old always-true guard) could never see a restart.
	consumed := scan.next > 0 || scan.awaiting || len(scan.streams) > 0 || len(scan.hits) > 0
	scan.hits = scan.hits[:0]
	scan.streams = nil
	scan.next = 0
	scan.awaiting = false
	if !consumed {
		// Nothing of the retired generation was consumed yet: rebinding the scan
		// to the document is not a restart.
		r.scan = scan
		return
	}
	scan.restarts++
	if scan.restarts > pagedScanRestartBudget {
		r.scan = nil
		if m != nil {
			m.status = fmt.Sprintf("search aborted: the transcript changed %d times; run /find %q again", scan.restarts, scan.query)
		}
		return
	}
	r.scan = scan
	if m != nil {
		m.status = fmt.Sprintf("transcript changed while searching; restarting the scan (%d/%d)", scan.restarts, pagedScanRestartBudget)
	}
}

// refresh (m.refreshPagedReplay) probes the index again after something that may
// have written the journal, such as a completed turn. An append only opens room
// before the live tail, so the user's scroll position and the resident bodies
// stay untouched.
func (r *pagedReplay) refresh(m *model) tea.Cmd {
	if r == nil || m == nil || !r.indexed {
		return nil
	}
	r.releaseInflight()
	return r.requestIndex(m)
}

// retire records a generation that must never be adopted again.
func (r *pagedReplay) retire(revision string) {
	if revision == "" {
		return
	}
	if r.retired == nil {
		r.retired = map[string]bool{}
	}
	r.retired[revision] = true
}

// applyIndex fixes the absolute block index space. A revision that only appends
// history grows the placeholder array and keeps the live tail; anything else
// rebuilds the document.
func (r *pagedReplay) applyIndex(m *model, payload json.RawMessage) tea.Cmd {
	reply, ok := decodePagedReply(payload)
	if !ok {
		m.err = "invalid transcript index: reply is not a JSON object"
		return nil
	}
	if r.session != "" && reply.SessionID != "" && reply.SessionID != r.session {
		return nil
	}
	if r.session == "" {
		r.session = reply.SessionID
	}
	if r.retired[reply.Revision] {
		return nil // a generation that a newer index already replaced
	}
	if reply.Revision != "" {
		if r.revision != "" && reply.Revision != r.revision {
			r.adopt(m, reply.Revision)
		} else {
			r.revision = reply.Revision
		}
	}
	total := r.total
	if reply.Total != nil {
		total = *reply.Total
	}
	total = max(0, total)
	r.failures, r.stalled, r.reason = 0, false, ""
	if len(reply.Context) > 0 {
		r.context = reply.Context
	}
	scan := r.scan
	switch {
	case !r.indexed || total < r.total:
		// A shrunken total is a rewrite: the document skeleton is rebuilt, which
		// also releases the scan's page and stream state.
		r.installBlocks(m, total)
	case total > r.total:
		// The journal appended blocks: open room before the live tail so the
		// absolute index of everything the user already sees does not move.
		m.insertPagedPlaceholders(r.total, total-r.total)
		r.total = total
	}
	if scan != nil && r.scan == nil {
		// installBlocks released the document; the search itself is still the
		// user's request, so it is restarted over the new block space.
		r.rearmScan(m, scan)
	}
	r.indexed = true
	m.initialReplayLoaded = true
	m.refreshTranscript()
	return r.ensure(m)
}

// installBlocks rebuilds the document skeleton: one placeholder per absolute
// block, then the startup notices the first replay must keep.
func (r *pagedReplay) installBlocks(m *model, blocks int) {
	// Startup diagnostics are live UI facts, not persisted rows. Only the
	// initial replay carries them forward, exactly like the classic restore.
	var startupNotices []transcriptui.Block
	if !m.initialReplayLoaded {
		for at := range m.transcript {
			if b := m.blocks[at]; b.Kind == "notice" || b.Kind == "error" {
				startupNotices = append(startupNotices, b)
			}
		}
	}
	r.releaseAll()
	m.surface.notices = nil
	m.fragments = nil
	m.clearTranscriptSearch()
	m.resetVirtualTranscript()
	m.transcript = make([]string, blocks)
	m.markdownRaw = nil
	m.markdownCache.reset()
	m.toolIndex = map[string]int{}
	m.blocks = map[int]transcriptui.Block{}
	r.total = blocks
	if blocks > 0 {
		m.welcomeHidden = true
	}
	for _, b := range startupNotices {
		at := len(m.transcript)
		m.transcript = append(m.transcript, "● "+b.Text)
		m.blocks[at] = b
	}
}

// releaseDeferred forgets the payloads a generation bump invalidates: range
// accumulations, in-flight requests and the scan's stream state. A caller that
// wants the search to survive the bump re-arms it through rearmScan.
func (r *pagedReplay) releaseDeferred() {
	for block, body := range r.bodies {
		r.bytes = max(0, r.bytes-len(body.data))
		delete(r.bodies, block)
	}
	r.inflight = nil
	r.scan = nil
	r.pins = nil
}

// releaseAll forgets every body without touching the model presentation.
func (r *pagedReplay) releaseAll() {
	r.resident = nil
	r.pages = nil
	r.bodies = nil
	r.bytes = 0
	r.inflight = nil
	r.pins = nil
	r.scan = nil
}

// applyPage materializes one page in place. Blocks the page does not cover keep
// their placeholder, so a partially resident document never shifts.
func (r *pagedReplay) applyPage(m *model, payload json.RawMessage) tea.Cmd {
	reply, ok := decodePagedReply(payload)
	if !ok {
		m.err = "invalid transcript page: reply is not a JSON object"
		return nil
	}
	if r.session != "" && reply.SessionID != "" && reply.SessionID != r.session {
		return nil
	}
	if !r.indexed {
		// A page without an index cannot be placed. Adopt the generation the
		// console reports and re-arm the index probe instead of guessing.
		if r.session == "" {
			r.session = reply.SessionID
		}
		if reply.Revision != "" {
			r.revision = reply.Revision
		}
		return r.ensure(m)
	}
	stale := reply.Revision != "" && r.revision != "" && reply.Revision != r.revision
	if stale && r.retired[reply.Revision] {
		return nil // a page of a generation that was already replaced
	}
	if stale {
		// The journal moved on between the index and this page. Drop the bodies of
		// the retired generation first, then store this page: its indexes belong
		// to the generation it reports.
		r.adopt(m, reply.Revision)
	}
	first := 0
	if reply.First != nil {
		first = *reply.First
	}
	items := make([]pagedItem, 0, len(reply.Items))
	for offset, raw := range reply.Items {
		var item pagedItem
		if err := json.Unmarshal(raw, &item); err != nil {
			continue // one unreadable body must not discard the page
		}
		if item.Index < first || (r.total > 0 && item.Index >= r.total) {
			item.Index = first + offset
		}
		if item.Index < 0 {
			continue
		}
		item.Kind = normalizePagedKind(item.Kind)
		if string(item.Arguments) == "null" {
			// `set_args` sends `args:null` together with an argsRef. The payload
			// is streamed separately, so the row must render "no arguments yet"
			// instead of the JSON literal.
			item.Arguments = nil
		}
		items = append(items, item)
	}
	r.clock++
	r.failures = 0
	r.settleInflight(first, len(items))
	if scan := r.scan; scan != nil && !stale && scan.awaiting {
		// Only the page the scan asked for is a scan page: a window reply that
		// raced the /find must be stored, not scanned a second time (which would
		// advance the scan past blocks it never read).
		r.scanPage(scan, items, reply)
		return r.scanStep(m)
	}
	// The journal can grow between the index and a page; follow the larger
	// total and let the index probe confirm it.
	if reply.Total != nil && *reply.Total > r.total {
		m.insertPagedPlaceholders(r.total, *reply.Total-r.total)
		r.total = *reply.Total
	}
	r.storePage(m, first, items)
	m.refreshTranscript()
	if stale {
		return tea.Batch(r.requestIndex(m), r.ensure(m))
	}
	if next := reply.Next; next != nil && *next > first && *next < r.total {
		// Follow the console's continuation only inside a span this frame asked for
		// (the painted window or a copy pin). A single pinned block must not start a
		// walk through the whole corpus, and must not have its own page evicted by
		// one: the pin would be released before the copy could read it.
		if limit, ok := r.wantedSpanLimit(m, *next); ok {
			return r.pageRequest(m, *next, limit)
		}
	}
	return r.ensure(m)
}

// storePage makes a page resident and re-materializes every block it covers.
func (r *pagedReplay) storePage(m *model, first int, items []pagedItem) {
	if r.resident == nil {
		r.resident = map[int]pagedItem{}
		r.pages = map[int]*pagedPage{}
	}
	page := r.pages[first]
	if page == nil {
		page = &pagedPage{first: first}
		r.pages[first] = page
	}
	page.used = r.clock
	touched := make([]int, 0, len(items))
	for _, item := range items {
		if held, ok := r.resident[item.Index]; ok {
			if !item.supersedes(held) {
				continue
			}
			// A patched block replaces the resident copy in place: a tool result
			// that arrived on a later journal line must upgrade a running item.
			r.bytes = max(0, r.bytes-held.bytes())
			if body := r.bodies[item.Index]; body != nil {
				r.bytes = max(0, r.bytes-len(body.data))
				delete(r.bodies, item.Index)
			}
			page.bytes += item.bytes() - held.bytes()
		} else {
			page.indices = append(page.indices, item.Index)
			page.bytes += item.bytes()
		}
		r.resident[item.Index] = item
		r.bytes += item.bytes()
		touched = append(touched, item.Index)
		r.registerBody(item)
	}
	if len(touched) == 0 {
		return
	}
	sort.Ints(touched)
	for _, block := range touched {
		r.rebuildBlock(m, block)
	}
	m.sortHiddenSources()
	r.evict(m, touched)
}

// registerBody schedules the deferred range read of a previewed payload. A block
// can carry two of them (a giant result and giant arguments), so the next field is
// registered once the previous one completes.
func (r *pagedReplay) registerBody(item pagedItem) {
	field, ref := item.deferredPayload()
	if field == "" {
		return
	}
	if r.bodies == nil {
		r.bodies = map[int]*pagedBody{}
	}
	if body := r.bodies[item.Index]; body != nil {
		if body.field == field && body.total == ref.Length {
			return // already scheduled for this payload
		}
		// A different payload (a patched result, or the next field of the same
		// block) replaces the accumulation; its bytes leave the budget first.
		r.bytes = max(0, r.bytes-len(body.data))
		delete(r.bodies, item.Index)
	}
	r.bodies[item.Index] = &pagedBody{block: item.Index, field: field, total: ref.Length}
}

// discardBlock removes every materialized trace of one paged block. Blocks after
// the paged region are live appends and are never touched.
func (r *pagedReplay) discardBlock(m *model, block int) {
	if block < 0 || block >= r.total {
		return
	}
	if block < len(m.transcript) {
		m.transcript[block] = ""
	}
	delete(m.blocks, block)
	delete(m.markdownRaw, block)
	m.markdownCache.delete(block)
	for key, at := range m.toolIndex {
		if at == block {
			delete(m.toolIndex, key)
		}
	}
	if len(m.hiddenSearchSources) > 0 {
		kept := m.hiddenSearchSources[:0]
		for _, source := range m.hiddenSearchSources {
			if source.block != block {
				kept = append(kept, source)
			}
		}
		clear(m.hiddenSearchSources[len(kept):])
		m.hiddenSearchSources = kept
	}
	m.invalidateTranscriptBlock(block)
}

// rebuildBlock is the only writer of paged block content, so a block never
// depends on the order in which its replies arrived. A reasoning block keeps the
// existing thinking panel; an answer block keeps the existing Markdown path.
func (r *pagedReplay) rebuildBlock(m *model, block int) {
	if block < 0 || block >= r.total || block >= len(m.transcript) {
		return
	}
	item, held := r.resident[block]
	r.discardBlock(m, block)
	if !held {
		return
	}
	if m.blocks == nil {
		m.blocks = map[int]transcriptui.Block{}
	}
	if m.toolIndex == nil {
		m.toolIndex = map[string]int{}
	}
	thought := item.Reasoning
	switch item.Kind {
	case "user":
		if item.Text == "" {
			return
		}
		m.transcript[block] = "> " + item.Text
		m.blocks[block] = transcriptui.Block{Kind: "user", Text: item.Text}
		m.welcomeHidden = true
	case "reasoning", "thinking":
		if item.Text == "" {
			return
		}
		// Its own absolute block: the console projects reasoning separately, and
		// folding it into the answer would renumber every later block. It still
		// renders with the existing thinking panel, directly above the answer.
		m.transcript[block] = fmt.Sprintf("💭 thought · %d lines", lenLines(item.Text))
		m.blocks[block] = transcriptui.Block{Kind: "thinking", Text: item.Text}
		m.addHiddenSource(block, "Thinking: "+item.Text)
		m.welcomeHidden = true
	case "assistant", "":
		if item.Text == "" && thought == "" {
			return
		}
		if item.Text != "" {
			m.transcript[block] = item.Text
			if m.markdownRaw == nil {
				m.markdownRaw = map[int]string{}
			}
			m.markdownRaw[block] = item.Text
		}
		// The classic restore only records a cell when the answer carries the
		// reasoning it streamed with; the answer itself renders from source.
		if thought != "" {
			m.blocks[block] = transcriptui.Block{Kind: "assistant", Reasoning: thought}
			m.addHiddenSource(block, "Thinking: "+thought)
		}
		m.welcomeHidden = true
	case "tool":
		// The journal's historical status words and the live wire phases
		// share one vocabulary: known statuses map to their canonical label,
		// unknown statuses settle the row on the journal's own word rather
		// than leaving it animating on a label no renderer recognizes.
		state := "running"
		if phase := transcriptui.ParseToolPhase(item.Status); phase.Terminal() {
			if phase == transcriptui.PhaseUnknown {
				state = item.Status
			} else {
				state = phase.Label()
			}
		}
		result := toolResultText(item.Result)
		m.transcript[block] = "• " + item.Name
		m.blocks[block] = transcriptui.Block{Kind: "tool", CallID: item.CallID, Name: item.Name, State: state, Arguments: item.Arguments, Text: result}
		if item.CallID != "" {
			m.toolIndex[item.CallID] = block
		}
		m.addHiddenSource(block, result)
		m.welcomeHidden = true
	default:
		if item.Text == "" {
			return
		}
		kind := item.Kind
		if kind == "unknown" {
			kind = "notice"
		}
		m.transcript[block] = "● " + item.Text
		m.blocks[block] = transcriptui.Block{Kind: kind, Text: item.Text}
	}
	m.invalidateTranscriptBlock(block)
}

// evict keeps the resident bodies inside the byte budget by dropping whole
// pages, least recently used first. Visible blocks, the blocks a page just
// filled and anything live stay.
//
// Pins are protected because a copy needs its range resident to produce text, but
// a pin is a request, not ownership: when nothing else can go and the document is
// still over budget, the pinned pages are released too (and their pins with them),
// so a selection that cannot fit cannot hold the session in memory. The retrying
// copy then refuses the range with a reason instead of paging forever.
func (r *pagedReplay) evict(m *model, keep []int) {
	budget := r.residentBudget()
	if r.bytes <= budget || len(r.pages) == 0 {
		return
	}
	if painted, beyond := m.pagedVisibleBlocks(); painted >= beyond {
		// Nothing is painted yet (the document has not been laid out): there is no
		// window to protect, so nothing may be released on the strength of it.
		return
	}
	protected := make(map[int]bool, len(keep))
	for _, block := range keep {
		protected[block] = true
	}
	pages := make([]*pagedPage, 0, len(r.pages))
	for _, page := range r.pages {
		pages = append(pages, page)
	}
	sort.Slice(pages, func(a, b int) bool { return pages[a].used < pages[b].used })
	for _, allowPinned := range []bool{false, true} {
		for _, page := range pages {
			if r.bytes <= budget {
				return
			}
			if r.pages[page.first] != page {
				continue // already released in an earlier pass
			}
			skip := false
			for _, index := range page.indices {
				if protected[index] || m.pagedBlockVisible(index) || (r.pins[index] && !allowPinned) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}
			r.dropPage(m, page)
		}
	}
}

// dropPage releases one page and re-materializes the blocks it leaves empty.
func (r *pagedReplay) dropPage(m *model, page *pagedPage) {
	for _, index := range page.indices {
		if item, held := r.resident[index]; held {
			r.bytes = max(0, r.bytes-item.bytes())
			delete(r.resident, index)
		}
		if body := r.bodies[index]; body != nil {
			r.bytes = max(0, r.bytes-len(body.data))
			delete(r.bodies, index)
		}
		// A pin on a released block would make the frame loop request the page
		// again only for this function to drop it: the copy re-pins on retry.
		delete(r.pins, index)
	}
	delete(r.pages, page.first)
	for _, block := range append([]int(nil), page.indices...) {
		r.rebuildBlock(m, block)
	}
	m.sortHiddenSources()
}

// sortHiddenSources restores document order after a page stitches history in
// out of order, so a fully resident document holds exactly the collapsed
// sources a classic restore holds, in the same order.
func (m *model) sortHiddenSources() {
	sources := m.hiddenSearchSources
	for i := 1; i < len(sources); i++ {
		if sources[i-1].block <= sources[i].block {
			continue
		}
		sort.SliceStable(sources, func(a, b int) bool { return sources[a].block < sources[b].block })
		return
	}
}

// pagedVisibleBlocks is the half-open block range a frame paints. It is derived
// from the row index (top/height) rather than from the last mount, so it is
// already correct on the frame a page arrives.
func (m *model) pagedVisibleBlocks() (first, last int) {
	v := m.virtualScroll
	if v == nil || len(v.heights) == 0 {
		return 0, -1
	}
	rows := v.totalRows()
	if rows <= 0 {
		return 0, -1
	}
	top := min(max(0, v.top), rows-1)
	bottom := min(rows, top+max(1, v.height))
	first = v.indexAt(top)
	last = v.indexAt(max(top, bottom-1)) + 1
	return first, last
}

func (m *model) pagedBlockVisible(block int) bool {
	first, last := m.pagedVisibleBlocks()
	return block >= first && block < last
}

// ensure (m.ensureTranscriptPages) requests the pages and deferred ranges the
// mounted window needs. It is cheap when the window is resident and idempotent
// while a request is in flight, so it can run after any message.
func (r *pagedReplay) ensure(m *model) tea.Cmd {
	if r == nil || m == nil {
		return nil
	}
	if r.stalled || m.host == nil {
		// A failed route is reported once through failed(); retrying it every
		// frame would hammer a console that already refused the replay.
		return nil
	}
	if !r.indexed {
		return r.requestIndex(m)
	}
	r.clock++
	// Release what the last frame left outside the budget and outside the painted
	// window. This is what makes the oversize-body exception a working set: the
	// moment a giant block scrolls out it is dropped, without waiting for another
	// page to arrive.
	r.evict(m, nil)
	if r.scan != nil {
		// A source scan owns the page channel: a stray window reply would be
		// consumed as a scan page, and vice versa. Its deferred payloads are read
		// through transcript_source instead of becoming resident bodies.
		return r.scanStep(m)
	}
	if r.total == 0 {
		return nil
	}
	var cmds []tea.Cmd
	for _, span := range r.wantedSpans(m) {
		for start := span[0]; start < span[1]; start += pagedPageLimit {
			end := min(start+pagedPageLimit, span[1])
			if r.covered(start, end) || r.requestPending(start, end) {
				continue
			}
			// Start at the first hole: a console that trims a reply by bytes still
			// makes progress even before its `next` arrives.
			at := start
			for at < end {
				if _, held := r.resident[at]; !held {
					break
				}
				at++
			}
			cmds = append(cmds, r.pageRequest(m, at, end-at))
		}
	}
	if body := r.wantedBody(m); body != nil {
		cmds = append(cmds, r.sourceRequest(m, body))
	}
	if len(cmds) == 0 {
		return nil
	}
	return tea.Batch(cmds...)
}

// wantedSpans is the block range of the mounted window plus any range a copy
// asked to keep resident.
func (r *pagedReplay) wantedSpans(m *model) [][2]int {
	var spans [][2]int
	first, last := 0, 0
	if visible, beyond := m.pagedVisibleBlocks(); visible < beyond {
		first, last = visible, min(beyond, r.total)
	} else {
		// Nothing is mounted yet (the first frame after the index, or a session
		// that has not painted): the document opens at its tail, so warm that
		// window instead of walking the history from block 0.
		first, last = max(0, r.total-pagedPageLimit), r.total
	}
	if first < last && first >= 0 {
		spans = append(spans, [2]int{first, last})
	}
	if len(r.pins) > 0 {
		pinned := make([]int, 0, len(r.pins))
		for index := range r.pins {
			pinned = append(pinned, index)
		}
		sort.Ints(pinned)
		low, high := pinned[0], pinned[0]+1
		for _, index := range pinned[1:] {
			if index <= high {
				high = index + 1
				continue
			}
			spans = append(spans, [2]int{low, high})
			low, high = index, index+1
		}
		spans = append(spans, [2]int{low, high})
	}
	return spans
}

// wantedBody picks one deferred payload of the painted window to continue. One
// chunk per frame keeps a giant body from blocking the UI.
//
// The gate is the *resident* byte count, never a ref length: only a body the
// document really holds may stop another body from starting. A payload bigger than
// the whole budget is the single documented oversize exception — it has to be read
// while it is painted, because the only other option is showing a
// REPLAY_PREVIEW_CHARS preview as if it were the body. The exception is exclusive:
// once one oversize payload (or pinned one) is resident, the next one waits for its
// turn and says so.
func (r *pagedReplay) wantedBody(m *model) *pagedBody {
	if len(r.bodies) == 0 || r.scan != nil {
		return nil
	}
	first, last := m.pagedVisibleBlocks()
	blocks := make([]int, 0, len(r.bodies))
	for block := range r.bodies {
		// A mounted block is read for display; a pinned block was asked for by a
		// copy, which needs the complete payload even while it is not painted.
		if (first < last && block >= first && block < last) || r.pins[block] {
			blocks = append(blocks, block)
		}
	}
	sort.Ints(blocks)
	budget := r.residentBudget()
	for _, block := range blocks {
		body := r.bodies[block]
		if body == nil || body.inflight || body.next >= body.total {
			continue
		}
		if r.bytes < budget {
			return body
		}
		// The budget is spent. The one oversize slot may still belong to a payload
		// that has scrolled out of the window: release that first, so the exception
		// follows the block the user is reading instead of the oldest one.
		r.releaseOversizeOffscreen(m, block)
		if r.oversizeBodyAllowed(m, block) {
			return body
		}
		if body.total > budget {
			r.noteOversizePreview(m, body)
		}
	}
	return nil
}

// oversizeBodyAllowed reports whether `block` may stream past the resident budget
// as the one oversize working set. It must be the only payload of that size held
// or being read, and it must be a payload the document has a reason to complete:
// painted, or pinned by a copy.
func (r *pagedReplay) oversizeBodyAllowed(m *model, block int) bool {
	budget := r.residentBudget()
	if !m.pagedBlockVisible(block) && !r.pins[block] {
		return false
	}
	for other, item := range r.resident {
		if other != block && item.bytes() > budget {
			return false
		}
	}
	for other, body := range r.bodies {
		if other == block || body.total <= budget {
			continue
		}
		if len(body.data) > 0 || body.inflight {
			return false
		}
	}
	return true
}

// releaseOversizeOffscreen drops a resident payload bigger than the whole budget
// once it is neither painted nor pinned, so the one oversize slot can move to the
// block the user is reading. Only the item is released; its page record stays,
// because the rest of the page is still useful and re-reading it costs a page.
func (r *pagedReplay) releaseOversizeOffscreen(m *model, except int) {
	budget := r.residentBudget()
	for block, item := range r.resident {
		if block == except || item.bytes() <= budget || m.pagedBlockVisible(block) || r.pins[block] {
			continue
		}
		r.bytes = max(0, r.bytes-item.bytes())
		delete(r.resident, block)
		if body := r.bodies[block]; body != nil {
			r.bytes = max(0, r.bytes-len(body.data))
			delete(r.bodies, block)
		}
		r.rebuildBlock(m, block)
		m.sortHiddenSources()
	}
}

// noteOversizePreview is the non-silent half of the exception: a payload that
// cannot be the resident one keeps its preview, and the document says so instead
// of presenting that preview as the whole body.
func (r *pagedReplay) noteOversizePreview(m *model, body *pagedBody) {
	if m == nil || body == nil {
		return
	}
	message := fmt.Sprintf("transcript block %d is %s, larger than the %s replay budget; showing its preview until the other large block scrolls out",
		body.block+1, pagedByteSize(body.total), pagedByteSize(r.residentBudget()))
	if m.status == message {
		return
	}
	m.status = message
}

// wantedSpanLimit reports how many blocks a wanted span still covers from `block`.
// It is also the "is this block part of what the frame asked for" test: a console
// continuation outside every span belongs to no window, so it is not followed.
func (r *pagedReplay) wantedSpanLimit(m *model, block int) (int, bool) {
	for _, span := range r.wantedSpans(m) {
		if block >= span[0] && block < span[1] {
			return max(1, min(pagedPageLimit, span[1]-block)), true
		}
	}
	return 0, false
}

// covered reports whether every block of a chunk is already resident.
func (r *pagedReplay) covered(first, end int) bool {
	for index := first; index < end; index++ {
		if _, held := r.resident[index]; !held {
			return false
		}
	}
	return true
}

// requestPending reports whether a request for this chunk is still plausible.
func (r *pagedReplay) requestPending(first, end int) bool {
	for at, issued := range r.inflight {
		if at >= first && at < end {
			if r.clock-issued < pagedRequestStale {
				return true
			}
			delete(r.inflight, at)
		}
	}
	return false
}

func (r *pagedReplay) settleInflight(first, count int) {
	if r.inflight == nil {
		return
	}
	delete(r.inflight, first)
	if count <= 0 {
		return
	}
	for at := range r.inflight {
		if at >= first && at < first+count {
			delete(r.inflight, at)
		}
	}
}

func (r *pagedReplay) pageRequest(m *model, first, limit int) tea.Cmd {
	if r.inflight == nil {
		r.inflight = map[int]uint64{}
	}
	r.inflight[first] = r.clock
	return requestAs(m.host, "transcript_page", "transcript_page", map[string]any{
		"session_id": r.session,
		"revision":   r.revision,
		"first":      first,
		"limit":      max(1, limit),
		"max_bytes":  pagedPageMaxBytes,
	})
}

func (r *pagedReplay) sourceRequest(m *model, body *pagedBody) tea.Cmd {
	body.inflight = true
	return r.sourceChunk(m, body.block, body.field, body.next)
}

// sourceChunk is one bounded range read of a deferred payload. `field` comes from
// the ref ("text"/"result"/"args"): the console resolves a payload by name, and an
// empty field would mean "auto" (text, or the result of a tool block), which is
// wrong for an arguments payload.
func (r *pagedReplay) sourceChunk(m *model, block int, field string, offset int) tea.Cmd {
	args := map[string]any{
		"session_id": r.session,
		"revision":   r.revision,
		"index":      block,
		"offset":     offset,
		"length":     pagedSourceChunkBytes,
	}
	if field != "" {
		args["field"] = field
	}
	return requestAs(m.host, "transcript_source", "transcript_source", args)
}

// applySource appends one bounded range of a deferred payload. The console
// answers with the clamped offset and the authoritative `next`, so a chunk that
// lands mid-character cannot desynchronise the accumulation.
func (r *pagedReplay) applySource(m *model, payload json.RawMessage) tea.Cmd {
	var reply pagedSourceReply
	if err := json.Unmarshal(payload, &reply); err != nil {
		m.err = "invalid transcript source: reply is not a JSON object"
		return nil
	}
	if r.session != "" && reply.SessionID != "" && reply.SessionID != r.session {
		return nil
	}
	if reply.Revision != "" && r.revision != "" && reply.Revision != r.revision {
		r.adopt(m, reply.Revision)
		return r.requestIndex(m)
	}
	if reply.Index == nil {
		return nil
	}
	// A running scan owns the range reads it issued: its payload never becomes
	// resident, so it must not fall through to the display accumulation.
	if scan := r.scan; scan != nil {
		if stream := scan.current(); stream != nil && stream.inflight && stream.block == *reply.Index {
			if reply.Field != "" && reply.Field != "auto" && stream.field != "" && reply.Field != stream.field {
				return nil // a payload the scan is not reading: never merge it
			}
			r.scanSource(scan, reply)
			return r.scanStep(m)
		}
	}
	body := r.bodies[*reply.Index]
	if body == nil || !body.inflight {
		// The block was released, or the body request was retired with a
		// generation/scan start: the range is requested again from the same
		// offset, so no byte is lost.
		return nil
	}
	if reply.Field != "" && reply.Field != "auto" && body.field != "" && reply.Field != body.field {
		// transcript_source resolves one payload per read. A range of another
		// payload of the same block must never be appended here: it would splice
		// the arguments (or the text) into the result being accumulated. The read is
		// retired and asked for again; a console that keeps answering for another
		// payload loses the body (the preview stays readable) and says so.
		body.inflight = false
		if body.failures++; body.failures >= 2 {
			r.bytes = max(0, r.bytes-len(body.data))
			delete(r.bodies, *reply.Index)
			if m != nil {
				m.status = "transcript body unavailable: transcript_source answered for another payload"
			}
		}
		return nil
	}
	body.inflight = false
	r.failures = 0
	if reply.Offset != body.next {
		// The console re-anchored or clamped the range: the discarded prefix is
		// no longer resident, so its bytes leave the budget with it.
		r.bytes = max(0, r.bytes-len(body.data))
		body.data = body.data[:0]
	}
	body.data = append(body.data, reply.Data...)
	body.next = reply.Offset + len(reply.Data)
	r.bytes += len(reply.Data)
	if reply.TotalBytes > 0 {
		body.total = reply.TotalBytes
	}
	if reply.Next == nil || body.next >= body.total {
		r.completeBody(m, body)
		return r.ensure(m)
	}
	m.refreshTranscript()
	return r.ensure(m)
}

// completeBody replaces the preview with the accumulated payload. The payload of
// the next deferred field of the same block, if any, is scheduled here.
func (r *pagedReplay) completeBody(m *model, body *pagedBody) {
	item, held := r.resident[body.block]
	delete(r.bodies, body.block)
	if !held {
		// The block was released while its payload streamed: the accumulated bytes
		// leave the budget with the accumulation.
		r.bytes = max(0, r.bytes-len(body.data))
		return
	}
	// The accumulation leaves the budget with the buffer it lived in, and the
	// materialized payload enters it: the preview it replaces was already charged,
	// so only the difference is added back.
	before := item.bytes()
	r.bytes = max(0, r.bytes-len(body.data))
	text := string(body.data)
	switch body.field {
	case "args":
		// `transcript_source` resolves the args payload as JSON text, which is
		// exactly what the tool row renders.
		item.Arguments = json.RawMessage(append([]byte(nil), body.data...))
		item.ArgsRef = nil
		item.ArgsBytes = len(body.data)
	case "result":
		if encoded, err := json.Marshal(text); err == nil {
			item.Result = encoded
		}
		item.ResultRef = nil
		item.ResultBytes = len(body.data)
	default:
		item.Text = text
		item.TextRef = nil
		item.TextBytes = len(body.data)
	}
	r.resident[body.block] = item
	r.bytes += item.bytes() - before
	r.registerBody(item)
	r.rebuildBlock(m, body.block)
	m.sortHiddenSources()
	m.refreshTranscript()
}

// find (used instead of findTranscript while paged) reads the complete corpus
// page by page. Pages are released after being scanned, so a match in a block
// that is not resident is still found without materializing the session, and a
// payload the page only previewed is streamed through `transcript_source`
// instead of being searched as its REPLAY_PREVIEW_CHARS prefix.
func (r *pagedReplay) find(m *model, query string) tea.Cmd {
	if r == nil || m == nil {
		return nil
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return nil
	}
	if !r.indexed {
		m.status = "transcript index is still loading"
		return r.ensure(m)
	}
	m.searchQuery = query
	m.searchHits = nil
	m.searchActive = -1
	if r.stalled {
		m.status = "transcript replay paused; search unavailable"
		return nil
	}
	// A display body that is already in flight cannot be told apart from the
	// scan's own range read, so its request is retired: ensure re-issues it from
	// the same offset once the scan is done.
	r.releaseInflight()
	r.scan = &pagedScan{query: query, needle: strings.ToLower(query)}
	m.status = "searching the session transcript…"
	// The first page is issued by the next ensure (Update runs it every frame), so
	// a caller that cannot return a command still gets a complete scan.
	return nil
}

// cancelScan abandons a running scan. The parent calls it when the query is
// cleared, so a retired /find cannot finish later and re-open its own hits.
func (r *pagedReplay) cancelScan(m *model) {
	if r == nil || r.scan == nil {
		return
	}
	r.scan = nil
	if m != nil && strings.HasPrefix(m.status, "searching the session") {
		m.status = ""
	}
}

// scanStep advances the scan by exactly one bounded read: a deferred payload of
// the page in hand first (so a page of giants cannot pile up), then the next
// corpus page.
func (r *pagedReplay) scanStep(m *model) tea.Cmd {
	scan := r.scan
	if scan == nil {
		return nil
	}
	if m.host == nil {
		r.finishScan(m)
		return nil
	}
	if len(scan.hits) >= maxTranscriptSearchHits {
		r.finishScan(m)
		return nil
	}
	// Deferred payloads are read before the next page: only the current chunk and
	// a needle-sized overlap are ever held.
	for len(scan.streams) > 0 {
		stream := scan.streams[0]
		if stream.next >= stream.total {
			scan.streams = scan.streams[1:]
			continue
		}
		if stream.inflight && r.clock-stream.issued < pagedRequestStale {
			return nil // the chunk is still on its way
		}
		stream.inflight = true
		stream.issued = r.clock
		scan.awaiting = false
		return r.sourceChunk(m, stream.block, stream.field, stream.next)
	}
	if scan.next >= r.total {
		r.finishScan(m)
		return nil
	}
	if scan.awaiting {
		if at, ok := r.inflight[scan.next]; ok && r.clock-at < pagedRequestStale {
			return nil // a scan page is already in flight
		}
		scan.awaiting = false // the reply never came: re-arm the read
	}
	first := scan.next
	scan.awaiting = true
	if r.inflight == nil {
		r.inflight = map[int]uint64{}
	}
	r.inflight[first] = r.clock
	return requestAs(m.host, "transcript_page", "transcript_page", map[string]any{
		"session_id": r.session,
		"revision":   r.revision,
		"first":      first,
		"limit":      pagedScanPageLimit,
		"max_bytes":  pagedPageMaxBytes,
	})
}

// scanPage searches one corpus page. Inline sources are searched directly; a
// source the page only previewed becomes a bounded range read, because the
// preview would drop every match past its end.
func (r *pagedReplay) scanPage(scan *pagedScan, items []pagedItem, reply pagedReply) {
	scan.awaiting = false
	next := scan.next
	for _, item := range items {
		// A resident body is authoritative only when it is complete: a preview
		// would silently miss everything past REPLAY_PREVIEW_CHARS.
		if held, ok := r.resident[item.Index]; ok && !held.pending() {
			item = held
		}
		for _, source := range pagedItemSources(item) {
			if len(scan.hits) >= maxTranscriptSearchHits {
				break
			}
			if source.deferred() {
				scan.streams = append(scan.streams, &pagedScanStream{
					block:  item.Index,
					field:  source.field,
					hidden: source.hidden,
					prefix: source.prefix,
					total:  source.ref.Length,
				})
				continue
			}
			scan.hits = searchTranscriptSource(source.text, scan.needle, item.Index, source.hidden, scan.hits)
		}
		next = max(next, item.Index+1)
	}
	if reply.Next != nil && *reply.Next > next {
		next = *reply.Next
	}
	if next <= scan.next {
		next = scan.next + 1 // a page that advances nothing must not loop
	}
	scan.next = next
}

// scanSource consumes one bounded range of a payload the scan is streaming. The
// payload never becomes a document body: the stream keeps the current chunk, a
// needle-sized overlap and the offsets already reported.
func (r *pagedReplay) scanSource(scan *pagedScan, reply pagedSourceReply) {
	stream := scan.current()
	if stream == nil {
		return
	}
	stream.inflight = false
	if reply.TotalBytes > 0 {
		stream.total = reply.TotalBytes
	}
	if reply.Offset != stream.next {
		// The console re-anchored or clamped the range, so the overlap is not a
		// prefix of this data and the reported offsets start over.
		stream.tail = ""
		stream.searched = 0
	}
	stream.read(scan, reply.Offset, reply.Data)
	if stream.next >= stream.total {
		scan.streams = scan.streams[1:]
	}
}

// read searches one chunk together with the overlap that was kept from the
// previous one, so a query that spans two ranges is found exactly once and never
// twice.
func (s *pagedScanStream) read(scan *pagedScan, offset int, data string) {
	window := s.tail + data
	base := offset - len(s.tail) // payload offset of window[0]
	haystack := strings.ToLower(window)
	for from := max(0, s.searched-base); from < len(haystack) && len(scan.hits) < maxTranscriptSearchHits; {
		at := strings.Index(haystack[from:], scan.needle)
		if at < 0 {
			break
		}
		at += from
		absolute := base + at
		if absolute >= s.searched {
			scan.hits = append(scan.hits, transcriptSearchHit{
				block:  s.block,
				offset: len(s.prefix) + absolute,
				length: len(scan.needle),
				hidden: s.hidden,
			})
			s.searched = absolute + len(scan.needle) // non-overlapping, same as classic
		}
		from = at + max(1, len(scan.needle))
	}
	// Every start before this offset has been looked at: keep only the bytes a
	// query can still reach back into.
	s.searched = max(s.searched, offset+len(data)-(len(scan.needle)-1))
	if len(scan.needle) > 1 {
		keep := min(len(scan.needle)-1, len(window))
		s.tail = window[len(window)-keep:]
	}
	s.next = offset + len(data)
}

func (r *pagedReplay) finishScan(m *model) {
	scan := r.scan
	r.scan = nil
	if scan == nil {
		return
	}
	sort.SliceStable(scan.hits, func(a, b int) bool {
		if scan.hits[a].block != scan.hits[b].block {
			return scan.hits[a].block < scan.hits[b].block
		}
		return scan.hits[a].offset < scan.hits[b].offset
	})
	// A re-delivered page can be scanned twice; a match is one document position.
	unique := scan.hits[:0]
	for _, hit := range scan.hits {
		if len(unique) > 0 {
			last := unique[len(unique)-1]
			if last.block == hit.block && last.offset == hit.offset && last.length == hit.length {
				continue
			}
		}
		unique = append(unique, hit)
	}
	clear(scan.hits[len(unique):])
	scan.hits = unique
	m.searchQuery = scan.query
	m.searchHits = scan.hits
	m.searchActive = -1
	if len(scan.hits) == 0 {
		m.status = fmt.Sprintf("no transcript matches for %q", scan.query)
	} else {
		m.navigateTranscriptSearch(false)
	}
	if scan.unreadable > 0 {
		// A payload the console refused is a hole in the scan: say so instead of
		// presenting a partial result as the whole session.
		m.status += fmt.Sprintf(" · %d payload(s) unreadable", scan.unreadable)
	}
}

// pagedSource is one searchable source of a block. The visible text is what the
// block shows; hidden text is collapsed tool output, reasoning or call arguments.
// A source the page only previewed carries no text at all: it carries the ref, and
// the scan streams the payload. Searching the preview instead would silently drop
// every match past REPLAY_PREVIEW_CHARS.
type pagedSource struct {
	text   string
	hidden bool
	prefix string // literal prefix the materialized source starts with
	field  string // deferred payload name ("text"/"result"/"args")
	ref    *pagedRef
}

// deferred reports whether the source has to be streamed through
// transcript_source instead of being searched as a string.
func (source pagedSource) deferred() bool { return source.ref != nil }

// pagedItemSources is the single definition of "the searchable sources of a
// block", shared by materialized search and the full-corpus scan.
func pagedItemSources(item pagedItem) []pagedSource {
	switch item.Kind {
	case "user":
		if item.Text == "" && item.TextRef == nil {
			return nil
		}
		source := pagedSource{text: "> " + item.Text, prefix: "> ", field: "text", ref: item.TextRef}
		if source.ref != nil {
			source.text = ""
		}
		return []pagedSource{source}
	case "reasoning", "thinking":
		if item.Text == "" && item.TextRef == nil {
			return nil
		}
		source := pagedSource{text: "Thinking: " + item.Text, hidden: true, prefix: "Thinking: ", field: "text", ref: item.TextRef}
		if source.ref != nil {
			source.text = ""
		}
		// The visible row is a line count. A preview cannot say how many lines the
		// payload has, so only its constant part is searchable at this block.
		summary := fmt.Sprintf("💭 thought · %d lines", lenLines(item.Text))
		if source.ref != nil {
			summary = "💭 thought · "
		}
		return []pagedSource{source, {text: summary}}
	case "assistant", "":
		sources := make([]pagedSource, 0, 2)
		if item.Reasoning != "" {
			sources = append(sources, pagedSource{text: "Thinking: " + item.Reasoning, hidden: true})
		}
		if item.Text != "" || item.TextRef != nil {
			source := pagedSource{field: "text", ref: item.TextRef}
			if source.ref == nil {
				source.text = item.Text
			}
			sources = append(sources, source)
		}
		return sources
	case "tool":
		// cetas-js ToolRow.getSearchText searches "name, arguments, result", so a
		// giant args payload (which arrives as `args:null` plus argsRef) is block
		// content like any other and must be streamed, not ignored.
		sources := []pagedSource{{text: "• " + item.Name}}
		switch args := string(item.Arguments); {
		case item.ArgsRef != nil:
			sources = append(sources, pagedSource{hidden: true, field: "args", ref: item.ArgsRef})
		case args != "" && args != "null":
			sources = append(sources, pagedSource{text: args, hidden: true})
		}
		if item.ResultRef != nil {
			sources = append(sources, pagedSource{hidden: true, field: "result", ref: item.ResultRef})
		} else if result := toolResultText(item.Result); result != "" {
			sources = append(sources, pagedSource{text: result, hidden: true})
		}
		return sources
	default:
		if item.Text == "" && item.TextRef == nil {
			return nil
		}
		source := pagedSource{text: "● " + item.Text, prefix: "● ", field: "text", ref: item.TextRef}
		if source.ref != nil {
			source.text = ""
		}
		return []pagedSource{source}
	}
}

// normalizePagedKind folds the spellings the projection may use.
func normalizePagedKind(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "":
		return ""
	case "thinking", "reason":
		return "reasoning"
	case "prompt", "question":
		return "user"
	case "answer", "completion":
		return "assistant"
	case "tool_call", "call":
		return "tool"
	}
	return strings.ToLower(strings.TrimSpace(kind))
}

// copyRange reads an inclusive block range. A block that is not resident, or
// whose payload is still a preview, cannot be produced synchronously: the range
// is pinned for the next ensure call and the caller retries.
//
// The pin set is bounded, because a copy is the one path that needs a whole range
// resident at once. A selection too large to hold is refused with a reason instead
// of pinning the session and growing the document without limit.
func (r *pagedReplay) copyRange(m *model, first, last int) (string, error) {
	if r == nil || m == nil {
		return "", errors.New("invalid transcript copy range")
	}
	if first < 0 || last < first || last >= m.transcriptBlockCount() {
		return "", errors.New("invalid transcript copy range")
	}
	if blocks := last - first + 1; blocks > pagedPinLimit {
		return "", fmt.Errorf("selection spans %d transcript entries and paged replay copies at most %d at once; copy a smaller range", blocks, pagedPinLimit)
	}
	if r.tooLargeToLoad(first, last) {
		return "", fmt.Errorf("selection needs more than the %s replay budget; copy a smaller range", pagedByteSize(r.residentBudget()))
	}
	waiting := -1
	// Blocks past the paged region are live appends: they are always materialized,
	// so a drag that includes the just-streamed answer copies normally.
	for block := first; block <= last && block < r.total; block++ {
		item, held := r.resident[block]
		if held && !item.partial() {
			continue
		}
		if waiting < 0 {
			waiting = block
		}
		r.pin(block)
	}
	if waiting >= 0 {
		if blocked := r.oversizeCopyBlocked(m, first, last); blocked >= 0 {
			// The pinned payload is larger than the whole budget and the one oversize
			// slot belongs to the block on screen: retrying would poll ensure for as
			// long as the session stays open, so the copy says what to do instead.
			for block := first; block <= last && block < r.total; block++ {
				delete(r.pins, block)
			}
			return "", fmt.Errorf("transcript block %d needs %s and another large block is resident; scroll it out, then copy again", blocked+1, pagedByteSize(r.resident[blocked].refBytes()))
		}
		return "", fmt.Errorf("transcript block %d is not loaded yet; pages are loading, retry in a moment", waiting+1)
	}
	// The range is resident and complete, so the classic formatter produces the
	// clipboard text; it must not re-enter the paged guard above.
	text, err := m.copySourceBlocks(first, last)
	if err == nil {
		// The selection was served: the pins have done their job and must not keep
		// the range resident for the rest of the session.
		r.pins = nil
	}
	return text, err
}

// oversizeCopyBlocked reports a pinned payload of the range that cannot become
// resident while another oversize payload is painted or pinned. It is the one
// waiting state that can never resolve on its own: ensure would answer "not
// loaded yet" until the other block scrolls out of the window.
func (r *pagedReplay) oversizeCopyBlocked(m *model, first, last int) int {
	budget := r.residentBudget()
	for block := first; block <= last && block < r.total; block++ {
		item, held := r.resident[block]
		if !held || !item.partial() || item.refBytes() <= budget {
			continue
		}
		if !r.oversizeBodyAllowed(m, block) {
			return block
		}
	}
	return -1
}

// tooLargeToLoad reports whether a copy range is already known to need more
// resident bytes than the document may hold. The largest single payload of the
// range is not counted: exactly one oversize payload is allowed at a time (see
// wantedBody), so copying one giant block stays possible while a range of them
// does not. Blocks that are not resident yet have no size on the wire — the count
// bound in copyRange is what covers those.
func (r *pagedReplay) tooLargeToLoad(first, last int) bool {
	known, largest := 0, 0
	for block := first; block <= last && block < r.total; block++ {
		item, held := r.resident[block]
		if !held {
			continue
		}
		size := item.bytes() + item.refBytes()
		known += size
		largest = max(largest, item.refBytes())
	}
	return known-largest > r.residentBudget()
}

// copyHistory is the 1-based form used by /copyhistory.
func (r *pagedReplay) copyHistory(m *model, first, last int) (string, error) {
	if first < 1 || last < first || last > r.total {
		return "", errors.New("invalid transcript copy range")
	}
	return r.copyRange(m, first-1, last-1)
}

func (r *pagedReplay) pin(block int) {
	if block < 0 || block >= r.total {
		return
	}
	if r.pins == nil {
		r.pins = map[int]bool{}
	}
	r.pins[block] = true
}

// insertPagedPlaceholders opens room for history that a newer revision
// appended. Live appends the TUI made after the last page stay where the user
// saw them, shifted by the exact number of new history blocks.
func (m *model) insertPagedPlaceholders(at, count int) {
	if count <= 0 {
		return
	}
	at = min(max(0, at), len(m.transcript))
	tail := append([]string(nil), m.transcript[at:]...)
	m.transcript = append(m.transcript[:at], make([]string, count)...)
	m.transcript = append(m.transcript, tail...)
	m.blocks = insertBlockMap(m.blocks, at, count)
	m.markdownRaw = insertBlockMap(m.markdownRaw, at, count)
	m.markdownCache.insert(at, count)
	for key, index := range m.toolIndex {
		if index >= at {
			m.toolIndex[key] = index + count
		}
	}
	for i := range m.hiddenSearchSources {
		if m.hiddenSearchSources[i].block >= at {
			m.hiddenSearchSources[i].block += count
		}
	}
	for key, index := range m.surface.notices {
		if index >= at {
			m.surface.notices[key] = index + count
		}
	}
	if m.document.live.valid && m.document.live.index >= at {
		m.document.live.index += count
		m.document.live.valid = false
	}
	m.document.selection = transcriptSelection{}
	insertVirtualHeights(m.virtualScroll, at, count, 3)
	if m.searchQuery != "" {
		m.searchHits = transcriptMatches(m.transcript, m.hiddenSearchSources, m.searchQuery)
		m.searchActive = min(m.searchActive, len(m.searchHits)-1)
	}
}

func insertBlockMap[T any](old map[int]T, at, count int) map[int]T {
	if old == nil {
		return nil
	}
	next := make(map[int]T, len(old)+count)
	for index, value := range old {
		if index >= at {
			index += count
		}
		next[index] = value
	}
	return next
}

// insertVirtualHeights keeps the Fenwick row index valid across an insertion in
// the middle of the document. Heights before the insertion do not move, so a
// scrolled-up viewport only shifts by the inserted rows. The revision vector is
// deliberately left shorter than the tree: virtualTranscript.sync resets the row
// cache on that length mismatch, which is the documented paged-insert contract.
func insertVirtualHeights(v *virtualTranscript, at, count, height int) {
	if v == nil || count <= 0 || at < 0 || at > len(v.heights) {
		return
	}
	rowOffset := 0
	for i := 0; i < at && i < len(v.heights); i++ {
		rowOffset += v.heights[i]
	}
	height = max(1, height)
	heights := make([]int, 0, len(v.heights)+count)
	heights = append(heights, v.heights[:at]...)
	for i := 0; i < count; i++ {
		heights = append(heights, height)
	}
	heights = append(heights, v.heights[at:]...)
	v.heights = heights
	// Rebuild the tree in one pass; a mid-document insert cannot be expressed by
	// the append-only API, and this path only runs on a revision bump.
	prefix := make([]int, len(heights)+1)
	for i, h := range heights {
		prefix[i+1] = prefix[i] + h
	}
	v.bit = make([]int, len(heights)+1)
	for i := 1; i <= len(heights); i++ {
		v.bit[i] = prefix[i] - prefix[i-(i&-i)]
	}
	if v.top >= rowOffset {
		v.top += count * height
	}
	v.clamp()
}
