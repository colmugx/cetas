package tui

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// pagedTestHost emulates the console's bounded replay routes
// (cetas-console/console/native_replay.mbt) from an in-memory corpus and records
// every request, so a test can assert what the TUI actually asked for.
type pagedTestHost struct {
	testHost
	session     string
	revision    string // journal generation: "<size>:<mtime>:<ns>"
	corpus      []pagedItem
	indexWindow int  // REPLAY_INDEX_WINDOW emulation (0 = whole corpus)
	pageCap     int  // max items per page, emulating a max_bytes trim
	noNext      bool // a console that trims without the continuation pointer
	inlineBytes int  // REPLAY_INLINE_BYTES emulation (0 = always inline)
	sourceError bool // the console refuses a deferred payload
	requests    []pagedTestRequest
}

type pagedTestRequest struct {
	command string
	args    map[string]any
}

func (h *pagedTestHost) Request(_ context.Context, command string, args any) (json.RawMessage, error) {
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, err
	}
	h.requests = append(h.requests, pagedTestRequest{command: command, args: decoded})
	switch command {
	case "transcript_index":
		return h.indexPayload(pagedArgInt(decoded, "first", -1), pagedArgInt(decoded, "limit", 0)), nil
	case "transcript_page":
		return h.pagePayload(pagedArgInt(decoded, "first", 0), pagedArgInt(decoded, "limit", 0)), nil
	case "transcript_source":
		if h.sourceError {
			return json.RawMessage(`{"error":"transcript tool block has no result yet"}`), nil
		}
		field, _ := decoded["field"].(string)
		return h.sourcePayload(pagedArgInt(decoded, "index", 0), field, pagedArgInt(decoded, "offset", 0), pagedArgInt(decoded, "length", 0)), nil
	}
	return json.RawMessage(`{}`), nil
}

func pagedArgInt(args map[string]any, key string, fallback int) int {
	value, ok := args[key].(float64)
	if !ok {
		return fallback
	}
	return int(value)
}

// indexPayload mirrors native_replay_index_json: a bounded WINDOW of light
// items, no first/next, and a string revision.
func (h *pagedTestHost) indexPayload(first, limit int) json.RawMessage {
	window := limit
	if window <= 0 {
		window = 400
	}
	if h.indexWindow > 0 {
		window = min(window, h.indexWindow)
	}
	start := first
	if start < 0 {
		start = max(0, len(h.corpus)-window)
	}
	end := min(start+window, len(h.corpus))
	items := make([]map[string]any, 0, max(0, end-start))
	for _, item := range h.corpus[start:end] {
		entry := map[string]any{
			"index":     item.Index,
			"kind":      item.Kind,
			"turnId":    item.TurnID,
			"textBytes": len(item.Text),
		}
		if item.CallID != "" {
			entry["callId"] = item.CallID
			entry["name"] = item.Name
			entry["status"] = item.Status
			entry["argsBytes"] = len(item.Arguments)
			entry["resultBytes"] = len(item.Result)
		}
		items = append(items, entry)
	}
	raw, _ := json.Marshal(map[string]any{
		"session_id": h.session,
		"revision":   h.revision,
		"total":      len(h.corpus),
		"context":    map[string]any{"tokens": 1234},
		"items":      items,
	})
	return raw
}

// pagePayload mirrors native_replay_page_json: absolute indexes, the existing
// transcript item schema, inline caps with refs, and `next` (null when done).
func (h *pagedTestHost) pagePayload(first, limit int) json.RawMessage {
	if limit <= 0 {
		limit = 100
	}
	if h.pageCap > 0 {
		limit = min(limit, h.pageCap)
	}
	first = max(0, first)
	end := min(first+limit, len(h.corpus))
	items := make([]map[string]any, 0, max(0, end-first))
	for _, item := range h.corpus[first:end] {
		entry := map[string]any{"index": item.Index, "kind": item.Kind, "turnId": item.TurnID}
		if item.Kind != "user" {
			entry["streaming"] = false
		}
		payload := item.Text
		if h.inlineBytes > 0 && len(payload) > h.inlineBytes {
			entry["text"] = payload[:512]
			entry["textRef"] = map[string]any{"index": item.Index, "field": "text", "offset": 0, "length": len(payload)}
		} else if payload != "" {
			entry["text"] = payload
		}
		if item.CallID != "" {
			entry["callId"] = item.CallID
			entry["name"] = item.Name
			entry["status"] = item.Status
		}
		if len(item.Arguments) > 0 {
			// set_args: beyond REPLAY_INLINE_BYTES the console sends a null body
			// plus a self-describing argsRef instead of the arguments.
			args := string(item.Arguments)
			if h.inlineBytes > 0 && len(args) > h.inlineBytes {
				entry["args"] = nil
				entry["argsRef"] = map[string]any{"index": item.Index, "field": "args", "offset": 0, "length": len(args)}
			} else {
				entry["args"] = json.RawMessage(item.Arguments)
			}
		}
		if len(item.Result) > 0 {
			result := toolResultText(item.Result)
			if h.inlineBytes > 0 && len(result) > h.inlineBytes {
				entry["result"] = result[:512]
				entry["resultRef"] = map[string]any{"index": item.Index, "field": "result", "offset": 0, "length": len(result)}
			} else {
				entry["result"] = result
			}
		}
		items = append(items, entry)
	}
	payload := map[string]any{
		"session_id": h.session,
		"revision":   h.revision,
		"first":      first,
		"total":      len(h.corpus),
		"items":      items,
	}
	var next any
	if end < len(h.corpus) && !h.noNext {
		next = end
	}
	payload["next"] = next
	raw, _ := json.Marshal(payload)
	return raw
}

// sourcePayload mirrors native_replay_source_json: one bounded range of the
// decoded payload plus the authoritative continuation offset.
func (h *pagedTestHost) sourcePayload(block int, field string, offset, length int) json.RawMessage {
	body := ""
	if block >= 0 && block < len(h.corpus) {
		item := h.corpus[block]
		// "auto" is the console default: text for a text block, the result for a
		// tool block. A ref names its own payload, so the client never guesses.
		switch field {
		case "args":
			body = string(item.Arguments)
		case "result":
			body = toolResultText(item.Result)
		case "text":
			body = item.Text
		default:
			body = item.Text
			if body == "" {
				body = toolResultText(item.Result)
			}
		}
	}
	if field == "" {
		field = "auto"
	}
	if length <= 0 || length > 1<<20 {
		length = 1 << 20
	}
	start := min(max(0, offset), len(body))
	end := min(start+length, len(body))
	payload := map[string]any{
		"session_id":  h.session,
		"revision":    h.revision,
		"index":       block,
		"field":       field,
		"offset":      start,
		"length":      end - start,
		"total_bytes": len(body),
		"data":        body[start:end],
	}
	var next any
	if end < len(body) {
		next = end
	}
	payload["next"] = next
	raw, _ := json.Marshal(payload)
	return raw
}

func (h *pagedTestHost) requestsNamed(command string) []pagedTestRequest {
	var out []pagedTestRequest
	for _, request := range h.requests {
		if request.command == command {
			out = append(out, request)
		}
	}
	return out
}

func (h *pagedTestHost) pageRequests() []pagedTestRequest { return h.requestsNamed("transcript_page") }

// pagedResults resolves a command tree into the correlated replies it would send
// back through Bubble Tea.
func pagedResults(cmd tea.Cmd) []commandResult {
	var results []commandResult
	var walk func(tea.Cmd)
	walk = func(next tea.Cmd) {
		if next == nil {
			return
		}
		switch msg := next().(type) {
		case tea.BatchMsg:
			for _, sub := range msg {
				walk(sub)
			}
		case commandResult:
			results = append(results, msg)
		}
	}
	walk(cmd)
	return results
}

// pagedDrive applies every reply the adapter asks for, the way the runtime
// would, so a test observes the real request/reply cycle.
func pagedDrive(t *testing.T, m *model, r *pagedReplay, cmd tea.Cmd) int {
	t.Helper()
	steps := 0
	queue := []tea.Cmd{cmd}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if next == nil {
			continue
		}
		if steps++; steps > 400 {
			t.Fatalf("paged replay did not settle: %d replies", steps)
		}
		switch msg := next().(type) {
		case tea.BatchMsg:
			queue = append(queue, msg...)
		case commandResult:
			follow, handled := r.apply(m, msg)
			if !handled {
				continue
			}
			queue = append(queue, follow)
		}
	}
	return steps
}

// pagedLoadAll materializes the whole corpus, the way a user scrolling through
// the session would, so a test can compare a fully resident document.
func pagedLoadAll(t *testing.T, m *model, r *pagedReplay, host *pagedTestHost) {
	t.Helper()
	for first := 0; first < len(host.corpus); first += pagedPageLimit {
		r.apply(m, commandResult{name: "transcript_page", payload: host.pagePayload(first, pagedPageLimit)})
	}
}

// pagedScanAll drives a paged source scan to completion, including a console
// that splits replies with `next` and a scan that has to stream deferred
// payloads through transcript_source.
func pagedScanAll(t *testing.T, m *model, r *pagedReplay) {
	t.Helper()
	for steps := 0; r.scan != nil; steps++ {
		if steps > 400 {
			t.Fatal("the source scan did not terminate")
		}
		// The test drives replies synchronously, so nothing is really in flight:
		// clearing the request state keeps the loop independent of dropped cmds.
		r.releaseInflight()
		cmd := r.ensure(m)
		if cmd == nil {
			t.Fatalf("scan stopped early at block %d (%d streams)", r.scan.next, len(r.scan.streams))
		}
		for _, result := range pagedResults(cmd) {
			follow, handled := r.apply(m, result)
			if !handled || follow == nil {
				continue
			}
			for _, nested := range pagedResults(follow) {
				r.apply(m, nested)
			}
		}
	}
}

func pagedUserCorpus(count int) []pagedItem {
	corpus := make([]pagedItem, 0, count)
	for index := 0; index < count; index++ {
		corpus = append(corpus, pagedItem{Index: index, Kind: "user", Text: fmt.Sprintf("prompt %d", index)})
	}
	return corpus
}

func pagedCorpusFrom(t *testing.T, payload string) []pagedItem {
	t.Helper()
	var decoded struct {
		Items []json.RawMessage `json:"items"`
	}
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		t.Fatalf("corpus payload: %v", err)
	}
	corpus := make([]pagedItem, 0, len(decoded.Items))
	for index, raw := range decoded.Items {
		var item pagedItem
		if err := json.Unmarshal(raw, &item); err != nil {
			t.Fatalf("corpus item %d: %v", index, err)
		}
		item.Index = index
		corpus = append(corpus, item)
	}
	return corpus
}

func pagedTranscriptModel(t *testing.T, corpus []pagedItem) (model, *pagedReplay, *pagedTestHost) {
	t.Helper()
	host := &pagedTestHost{session: "s-1", revision: "2048:1700000000:0", corpus: corpus, indexWindow: 400}
	m, r := pagedHostModel(t, host)
	return m, r, host
}

// pagedHostModel attaches a paged document to a host the test configured itself:
// inline caps, a refusing console, or a journal that is rewritten mid-session.
func pagedHostModel(t *testing.T, host *pagedTestHost) (model, *pagedReplay) {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = host.session
	m.host = host
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))
	return m, r
}

// A paged replay of blocks the classic restore also projects unchanged must
// present exactly the same document: sources, cells, collapsed entries, pixels.
func TestPagedReplayMatchesClassicRestore(t *testing.T) {
	payload := `{"items":[
		{"kind":"user","text":"hello"},
		{"kind":"assistant","text":"answer one"},
		{"kind":"tool","callId":"c-1","name":"read","args":{"path":"a.go"},"status":"done","result":"file body"},
		{"kind":"assistant","text":"answer two"}
	]}`
	classic := newModel()
	classic.width, classic.height = 80, 24
	classic.resize()
	classic.session = "s-1"
	next, _ := classic.Update(commandResult{name: "session_transcript", payload: json.RawMessage(payload)})
	classic = next.(model)

	paged, r, host := pagedTranscriptModel(t, pagedCorpusFrom(t, payload))
	pagedLoadAll(t, &paged, r, host)
	paged.width, paged.height = 80, 24
	paged.resize()

	if want, got := classic.transcriptBlockCount(), paged.transcriptBlockCount(); want != got {
		t.Fatalf("block count drifted: classic=%d paged=%d", want, got)
	}
	if !reflect.DeepEqual(classic.transcript, paged.transcript) {
		t.Fatalf("sources drifted:\n classic %#v\n paged   %#v", classic.transcript, paged.transcript)
	}
	if !reflect.DeepEqual(classic.blocks, paged.blocks) {
		t.Fatalf("cells drifted:\n classic %#v\n paged   %#v", classic.blocks, paged.blocks)
	}
	if !reflect.DeepEqual(classic.markdownRaw, paged.markdownRaw) {
		t.Fatalf("markdown sources drifted:\n classic %#v\n paged   %#v", classic.markdownRaw, paged.markdownRaw)
	}
	if !reflect.DeepEqual(classic.hiddenSearchSources, paged.hiddenSearchSources) {
		t.Fatalf("collapsed sources drifted:\n classic %#v\n paged   %#v", classic.hiddenSearchSources, paged.hiddenSearchSources)
	}
	if got, want := ansi.Strip(paged.viewport.GetContent()), ansi.Strip(classic.viewport.GetContent()); got != want {
		t.Fatalf("rendered document drifted:\n paged   %q\n classic %q", got, want)
	}
	r.find(&paged, "file body")
	pagedScanAll(t, &paged, r)
	if len(paged.searchHits) != 1 || paged.searchHits[0].block != 2 || !paged.searchHits[0].hidden {
		t.Fatalf("paged replay lost a collapsed source: %#v", paged.searchHits)
	}
}

// The index is a bounded light window without first/next. The document must
// still be sized by `total`, and only the mounted window may be fetched.
func TestPagedReplayIndexProbeSizesTheWholeDocument(t *testing.T) {
	host := &pagedTestHost{session: "s-1", revision: "9:9:9", corpus: pagedUserCorpus(2000), indexWindow: 400}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()

	cmd := r.start(&m)
	results := pagedResults(cmd)
	indexes := host.requestsNamed("transcript_index")
	if len(indexes) != 1 {
		t.Fatalf("start must probe the index: %#v", host.requests)
	}
	if got := pagedArgInt(indexes[0].args, "limit", 0); got != pagedIndexProbeLimit {
		t.Fatalf("index probe asked for a light window of %d items", got)
	}
	if first := pagedArgInt(indexes[0].args, "first", -1); first != 0 {
		t.Fatalf("index probe first=%d", first)
	}
	if len(results) != 1 || results[0].name != "transcript_index" {
		t.Fatalf("index reply missing: %#v", results)
	}
	follow, handled := r.apply(&m, results[0])
	if !handled || !r.active() {
		t.Fatal("index reply not adopted")
	}
	if r.total != 2000 || len(m.transcript) != 2000 || len(m.virtualScroll.heights) != 2000 {
		t.Fatalf("document skeleton: total=%d transcript=%d heights=%d", r.total, len(m.transcript), len(m.virtualScroll.heights))
	}
	for index, source := range m.transcript {
		if source != "" {
			t.Fatalf("index fetched a body at %d: %q", index, source)
		}
	}
	if !strings.Contains(string(r.contextPayload()), "1234") {
		t.Fatalf("index context metadata lost: %q", r.contextPayload())
	}
	if follow == nil {
		t.Fatal("a fully cold window must request pages")
	}
	pagedResults(follow)
	pages := host.pageRequests()
	if len(pages) == 0 {
		t.Fatal("no page requested for the mounted window")
	}
	requested := 0
	for _, page := range pages {
		requested += pagedArgInt(page.args, "limit", 0)
		if page.args["revision"] != "9:9:9" {
			t.Fatalf("page request lost the string revision: %#v", page.args)
		}
		if page.args["max_bytes"] != float64(pagedPageMaxBytes) {
			t.Fatalf("page request lost the byte cap: %#v", page.args)
		}
		if first := pagedArgInt(page.args, "first", -1); first == 0 {
			t.Fatal("a tail-mounted window asked for the oldest page")
		}
	}
	if requested >= 2000 {
		t.Fatalf("a cold window requested the whole history: %d blocks", requested)
	}
}

// A payload above REPLAY_INLINE_BYTES arrives as a preview plus a ref; the
// adapter streams the ranges while the block is mounted.
func TestPagedReplayGiantBodyStreamsRanges(t *testing.T) {
	body := strings.Repeat("0123456789", 60_000) // 600 KB: preview + several ranges
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: "read the report"},
		{Index: 1, Kind: "assistant", Text: body},
	}
	host := &pagedTestHost{session: "s-1", revision: "600000:1:1", corpus: corpus, inlineBytes: 1024}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))

	sources := host.requestsNamed("transcript_source")
	if len(sources) == 0 {
		t.Fatal("a previewed body must be fetched through transcript_source")
	}
	if _, waiting := r.bodies[1]; waiting {
		t.Fatalf("the deferred body did not complete: next=%d", r.bodies[1].next)
	}
	if m.markdownRaw[1] != body || m.transcript[1] != body {
		t.Fatalf("block did not receive the full body: %d of %d bytes", len(m.transcript[1]), len(body))
	}
	if r.resident[1].partial() {
		t.Fatal("the completed body still looks like a preview")
	}
	for _, request := range sources {
		if request.args["revision"] != "600000:1:1" || pagedArgInt(request.args, "index", -1) != 1 {
			t.Fatalf("range request: %#v", request.args)
		}
	}
	if len(sources) < 2 {
		t.Fatalf("a 600 KB body must arrive in several ranges: %d", len(sources))
	}
	// A range error must not lose the preview or wedge the document.
	if _, handled := r.apply(&m, commandResult{name: "transcript_source", payload: json.RawMessage(`{"error":"transcript block has no text payload"}`)}); !handled {
		t.Fatal("source error not consumed")
	}
	if m.err != "" {
		t.Fatalf("recoverable source error became fatal: %q", m.err)
	}
}

// pagedPreviewBlock drives a document to the point where one page is resident and
// the payload of `block` is still only a preview: the frame-level ensure that
// would stream it is deliberately not driven.
func pagedPreviewBlock(t *testing.T, host *pagedTestHost, block int) (model, *pagedReplay) {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = host.session
	m.host = host
	r := newPagedReplay()
	if _, handled := r.apply(&m, commandResult{name: "transcript_index", payload: host.indexPayload(0, pagedIndexProbeLimit)}); !handled {
		t.Fatal("index reply not adopted")
	}
	m.jumpToTranscriptBlock(block)
	first, last := m.pagedVisibleBlocks()
	if block < first || block >= last {
		t.Fatalf("fixture: block %d is not in the painted window %d..%d", block, first, last)
	}
	r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(first, pagedPageLimit)})
	if _, held := r.resident[block]; !held {
		t.Fatalf("fixture: block %d is not resident", block)
	}
	// The frame that stored the page also asked for the first range read; this
	// fixture drops that command, so its request is retired the same way a lost
	// reply is (the range is simply read again from the same offset).
	r.releaseInflight()
	return m, r
}

// pagedResidentBytes is the accounting invariant behind the resident budget: r.bytes
// must equal exactly what the document holds — the payload strings of the resident
// blocks plus the range chunks accumulated for deferred payloads — and never a ref
// length, a page estimate or a released buffer.
func pagedResidentBytes(r *pagedReplay) int {
	total := 0
	for _, item := range r.resident {
		total += item.bytes()
	}
	for _, body := range r.bodies {
		total += len(body.data)
	}
	return total
}

func pagedAssertAccounting(t *testing.T, r *pagedReplay, when string) {
	t.Helper()
	if want := pagedResidentBytes(r); r.bytes != want {
		t.Fatalf("%s: resident accounting drifted: r.bytes=%d holds %d bytes", when, r.bytes, want)
	}
}

// B2: `pagedItem.bytes` charged a payload its whole ref length the moment its page
// arrived, while the body itself was still a REPLAY_PREVIEW_CHARS preview. A body
// larger than the resident budget therefore pushed the document over the budget
// before a single range read, wantedBody refused to start it, and the block stayed
// a 512-character preview forever — silently, with no error and no way to read it.
//
// Only resident bytes may be charged. A painted payload larger than the whole
// budget is the one documented oversize working-set exception: it completes in
// place through bounded ranges, and it is released the moment it scrolls out.
func TestPagedReplayGiantVisibleBodyCompletesAsOneOversizeException(t *testing.T) {
	body := strings.Repeat("0123456789abcdef", 589_824) // 9 MiB, above the 8 MiB budget
	giant := 119
	corpus := pagedUserCorpus(120)
	corpus[giant] = pagedItem{Index: giant, Kind: "assistant", Text: body}
	host := &pagedTestHost{session: "s-1", revision: "9437200:1:1", corpus: corpus, inlineBytes: 1024}
	m, r := pagedPreviewBlock(t, host, giant)
	if !r.resident[giant].partial() || len(m.transcript[giant]) >= len(body) {
		t.Fatalf("fixture: the body must start as a preview: %d of %d bytes", len(m.transcript[giant]), len(body))
	}
	if r.bytes >= r.residentBudget() {
		t.Fatalf("an unfetched ref was charged its full length: %d >= budget %d", r.bytes, r.residentBudget())
	}
	pagedAssertAccounting(t, r, "a preview is resident")

	pagedDrive(t, &m, r, r.ensure(&m))
	held := r.resident[giant]
	if held.partial() {
		t.Fatalf("the painted giant body never finished: %d of %d bytes resident", len(held.Text), len(body))
	}
	if m.transcript[giant] != body || m.markdownRaw[giant] != body {
		t.Fatalf("the giant body was truncated: %d of %d bytes", len(m.transcript[giant]), len(body))
	}
	// The exception is exactly one payload: nothing else may stay over budget.
	if slack := r.bytes - len(body); slack > r.residentBudget() {
		t.Fatalf("the oversize exception is unbounded: %d bytes beside the one body", slack)
	}
	pagedAssertAccounting(t, r, "the giant body completed")
	sources := host.requestsNamed("transcript_source")
	if len(sources) < 2 {
		t.Fatalf("a 9 MiB body must arrive in bounded ranges: %d", len(sources))
	}
	for _, request := range sources {
		if got := pagedArgInt(request.args, "length", 0); got > pagedSourceChunkBytes {
			t.Fatalf("range read exceeded the bounded chunk size: %d", got)
		}
	}

	// Scrolling the giant out of the window releases it immediately: the exception
	// is a working set, not a resident block.
	m.scrollTranscript(-1_000_000)
	if m.pagedBlockVisible(giant) {
		t.Fatal("fixture: the giant is still painted")
	}
	r.ensure(&m)
	if _, resident := r.resident[giant]; resident {
		t.Fatal("the oversize body stayed resident after scrolling out")
	}
	if m.transcript[giant] != "" {
		t.Fatalf("the released block kept its body: %d bytes", len(m.transcript[giant]))
	}
	if r.bytes > r.residentBudget() {
		t.Fatalf("the document did not return to the budget: %d > %d", r.bytes, r.residentBudget())
	}
	pagedAssertAccounting(t, r, "the giant body was released")

	// Scrolling back re-reads it through the same bounded ranges instead of
	// resurrecting a body of a released window.
	m.jumpToTranscriptBlock(giant)
	pagedDrive(t, &m, r, r.ensure(&m))
	if m.transcript[giant] != body {
		t.Fatalf("a released giant body was not re-read: %d of %d bytes", len(m.transcript[giant]), len(body))
	}
	pagedAssertAccounting(t, r, "the giant body was re-read")
}

// The pin set is a request, not ownership: a pinned page may not keep the document
// over budget on its own, and the pin goes with the page so the frame loop cannot
// keep re-requesting what eviction drops.
func TestPagedPinnedPageCannotOutliveTheBudget(t *testing.T) {
	corpus := pagedUserCorpus(80)
	corpus[0] = pagedItem{Index: 0, Kind: "assistant", Text: strings.Repeat("old answer body ", 200)}
	host := &pagedTestHost{session: "s-1", revision: "80:1:1", corpus: corpus}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	r.budget = 1024 // smaller than the one block a copy asks for
	if _, handled := r.apply(&m, commandResult{name: "transcript_index", payload: host.indexPayload(0, pagedIndexProbeLimit)}); !handled {
		t.Fatal("index reply not adopted")
	}
	// A copy asks for the oldest block, which is far outside the painted tail.
	if _, err := r.copyHistory(&m, 1, 1); err == nil {
		t.Fatal("a released block was copied without loading it")
	}
	if !r.pins[0] {
		t.Fatal("a retryable copy must pin the block it is waiting for")
	}
	oldest := func() int {
		count := 0
		for _, request := range host.pageRequests() {
			if pagedArgInt(request.args, "first", -1) == 0 {
				count++
			}
		}
		return count
	}
	// The pinned block alone is larger than the budget: the page cannot stay.
	pagedDrive(t, &m, r, r.ensure(&m))
	if oldest() != 1 {
		t.Fatalf("the pin did not read its page once: %d requests", oldest())
	}
	if len(r.pins) != 0 {
		t.Fatalf("eviction kept %d pins on released blocks", len(r.pins))
	}
	if _, held := r.resident[0]; held {
		t.Fatal("the pinned page stayed over the resident budget")
	}
	if r.bytes > r.residentBudget() {
		t.Fatalf("a pin held the document over the budget: %d > %d", r.bytes, r.residentBudget())
	}
	pagedAssertAccounting(t, r, "a pinned page was released")
	// The pin is gone, so the frame loop does not re-request the released page.
	if cmd := r.ensure(&m); cmd != nil {
		pagedDrive(t, &m, r, cmd)
	}
	if got := oldest(); got != 1 {
		t.Fatalf("a released pin kept re-requesting its page: %d requests", got)
	}
	// A copy always re-pins, and an unfittable pin is reported, not looped on.
	if _, err := r.copyHistory(&m, 1, 1); err == nil || !strings.Contains(err.Error(), "not loaded yet") {
		t.Fatalf("a copy of a released block must stay retryable: %v", err)
	}
	if len(r.pins) != 1 {
		t.Fatalf("the retry did not pin its range: %v", r.pins)
	}
}

// Bodies beyond the resident budget are released; live appends never are.// Bodies beyond the resident budget are released; live appends never are.
func TestPagedReplayEvictsBeyondBudgetAndKeepsLiveBlocks(t *testing.T) {
	corpus := pagedUserCorpus(80)
	for index := range corpus {
		corpus[index].Text = strings.Repeat(fmt.Sprintf("body %d ", index), 40)
	}
	host := &pagedTestHost{session: "s-1", revision: "80:1:1", corpus: corpus}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	r.budget = 4096
	r.start(&m)
	if _, handled := r.apply(&m, commandResult{name: "transcript_index", payload: host.indexPayload(0, 1)}); !handled {
		t.Fatal("index reply not adopted")
	}
	// A live turn lands after the replay: it must survive every eviction.
	m.appendUser("live prompt")
	live := len(m.transcript) - 1
	for _, first := range []int{0, 8, 16, 24} {
		r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(first, 8)})
	}
	if r.bytes > r.residentBudget() {
		t.Fatalf("resident bodies exceed the budget: %d > %d", r.bytes, r.residentBudget())
	}
	if m.transcript[0] != "" || m.blocks[0].Text != "" {
		t.Fatalf("oldest page was not evicted: %q %#v", m.transcript[0], m.blocks[0])
	}
	if m.transcript[live] != "> live prompt" || m.blocks[live].Kind != "user" {
		t.Fatalf("eviction erased a live append: %q %#v", m.transcript[live], m.blocks[live])
	}
	// Re-requesting a released page restores it in place.
	r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(0, 8)})
	if m.transcript[0] == "" {
		t.Fatal("a released page could not be fetched again")
	}
	if m.transcript[live] != "> live prompt" {
		t.Fatal("re-fetching history moved the live append")
	}
}

// Search reads the complete corpus, not only the resident pages.
func TestPagedReplaySearchScansTheWholeCorpus(t *testing.T) {
	corpus := pagedUserCorpus(200)
	corpus[7].Text = "needle in the oldest message"
	corpus[170].Text = "needle in a newer message"
	m, r, host := pagedTranscriptModel(t, corpus)
	host.pageCap = 32 // replies are trimmed before `next`
	before := r.bytes

	r.find(&m, "NEEDLE")
	if r.scan == nil {
		t.Fatal("search over a paged document must start a scan")
	}
	if cmd := r.ensure(&m); cmd == nil {
		t.Fatal("the frame after a find must issue the first scan page")
	}
	pagedScanAll(t, &m, r)
	if len(m.searchHits) != 2 {
		t.Fatalf("scan missed matches: %#v", m.searchHits)
	}
	if m.searchHits[0].block != 7 || m.searchHits[0].hidden || m.searchHits[1].block != 170 {
		t.Fatalf("scan hits are not in absolute block order: %#v", m.searchHits)
	}
	if m.searchActive != 0 || !strings.Contains(m.status, "find 1/2") {
		t.Fatalf("scan did not navigate to the first match: %q", m.status)
	}
	if r.bytes != before {
		t.Fatalf("a scan made bodies resident: %d -> %d", before, r.bytes)
	}
}

// A page beyond REPLAY_INLINE_BYTES carries a REPLAY_PREVIEW_CHARS preview plus a
// self-describing ref. Searching that preview would silently miss every match
// further into the payload, so the scan streams the deferred body through
// transcript_source — in bounded ranges, without making it resident.
func TestPagedSearchStreamsPayloadsBeyondThePreview(t *testing.T) {
	filler := strings.Repeat("filler ", 1200) // 8.4 KB: far past a 512-char preview
	corpus := pagedUserCorpus(400)
	corpus[3] = pagedItem{Index: 3, Kind: "assistant", Text: filler + "needle at the end of the answer"}
	corpus[17] = pagedItem{
		Index: 17, Kind: "tool", CallID: "c-1", Name: "bash", Status: "done",
		Result: mustPagedJSON(t, filler+"needle at the end of the tool result"),
	}
	host := &pagedTestHost{session: "s-1", revision: "90000:1:1", corpus: corpus, inlineBytes: 4096}
	m, r := pagedHostModel(t, host)
	if len(r.resident) == 0 {
		t.Fatal("fixture: the mounted tail must be resident")
	}
	resident := r.bytes
	if strings.Contains(m.transcript[3], "needle") || strings.Contains(m.transcript[17], "needle") {
		t.Fatal("fixture: the needle must sit past the preview")
	}

	r.find(&m, "needle")
	if r.scan == nil {
		t.Fatal("search over a paged document must start a scan")
	}
	if cmd := r.ensure(&m); cmd == nil {
		t.Fatal("the frame after a find must issue the first scan page")
	}
	pagedScanAll(t, &m, r)

	if len(m.searchHits) != 2 {
		t.Fatalf("the scan searched previews instead of the payloads: %#v", m.searchHits)
	}
	if m.searchHits[0].block != 3 || m.searchHits[1].block != 17 || !m.searchHits[1].hidden {
		t.Fatalf("hits are not the deferred payload matches: %#v", m.searchHits)
	}
	if r.bytes != resident {
		t.Fatalf("a scan made bodies resident: %d -> %d", resident, r.bytes)
	}
	sources := host.requestsNamed("transcript_source")
	if len(sources) < 2 {
		t.Fatalf("the scan never read the previewed payloads: %d", len(sources))
	}
	fields := map[string]bool{}
	for _, request := range sources {
		if got := pagedArgInt(request.args, "length", 0); got != pagedSourceChunkBytes {
			t.Fatalf("scan range read is not the bounded chunk size: %d", got)
		}
		field, ok := request.args["field"].(string)
		if !ok || field == "" || field == "auto" {
			t.Fatalf("a ref is self-describing; the scan must pass its field back: %#v", request.args)
		}
		fields[field] = true
	}
	if !fields["text"] || !fields["result"] {
		t.Fatalf("the scan did not read both deferred payloads: %#v", fields)
	}
}

// A query can straddle two source ranges. The scan keeps only a needle-sized
// overlap, so a split match is found exactly once instead of being dropped (or
// counted twice).
func TestPagedSearchFindsQueriesSpanningSourceChunks(t *testing.T) {
	needle := "cross-chunk-needle"
	filler := strings.Repeat("a", pagedSourceChunkBytes-5) // the first range ends inside the needle
	corpus := pagedUserCorpus(400)
	corpus[2] = pagedItem{Index: 2, Kind: "assistant", Text: filler + needle + strings.Repeat("b", 2048)}
	host := &pagedTestHost{session: "s-1", revision: "300000:1:1", corpus: corpus, inlineBytes: 4096}
	m, r := pagedHostModel(t, host)

	r.find(&m, needle)
	pagedScanAll(t, &m, r)
	if len(m.searchHits) != 1 {
		t.Fatalf("a match split across ranges was missed or duplicated: %#v", m.searchHits)
	}
	hit := m.searchHits[0]
	if hit.block != 2 || hit.offset != len(filler) || hit.length != len(needle) {
		t.Fatalf("split match at %d/%d, want block 2 offset %d: %#v", hit.block, hit.offset, len(filler), hit)
	}
	if sources := host.requestsNamed("transcript_source"); len(sources) < 2 {
		t.Fatalf("the fixture did not split the payload: %d ranges", len(sources))
	}
}

// Beyond REPLAY_INLINE_BYTES the console sends `args:null` plus an argsRef. Those
// arguments are block content (cetas-js ToolRow.getSearchText searches them), so
// the scan streams them like any other deferred payload.
func TestPagedSearchCoversDeferredToolArguments(t *testing.T) {
	args := `{"cmd":"` + strings.Repeat("noise ", 900) + `needle-in-args"}`
	corpus := pagedUserCorpus(400)
	corpus[4] = pagedItem{
		Index: 4, Kind: "tool", CallID: "c-9", Name: "bash", Status: "running",
		Arguments: json.RawMessage(args),
	}
	host := &pagedTestHost{session: "s-1", revision: "9000:1:1", corpus: corpus, inlineBytes: 2048}
	var page struct {
		Items []pagedItem `json:"items"`
	}
	if err := json.Unmarshal(host.pagePayload(4, 1), &page); err != nil {
		t.Fatalf("fixture page: %v", err)
	}
	if len(page.Items) != 1 || page.Items[0].ArgsRef == nil || string(page.Items[0].Arguments) != "null" {
		t.Fatalf("fixture: deferred arguments must arrive as argsRef: %#v", page.Items)
	}
	m, r := pagedHostModel(t, host)
	if _, held := r.resident[4]; held {
		t.Fatal("fixture: block 4 must sit outside the mounted tail")
	}

	r.find(&m, "needle-in-args")
	pagedScanAll(t, &m, r)
	if len(m.searchHits) != 1 || m.searchHits[0].block != 4 || !m.searchHits[0].hidden {
		t.Fatalf("deferred tool arguments were not searched: %#v", m.searchHits)
	}
	for _, request := range host.requestsNamed("transcript_source") {
		if request.args["field"] == "args" {
			return
		}
	}
	t.Fatal("the scan never asked for the args payload")
}

// A payload the console refuses must be visible in the result: /find must never
// present a scan it could not finish as a complete one.
func TestPagedSearchReportsUnreadablePayloads(t *testing.T) {
	corpus := pagedUserCorpus(400)
	corpus[4] = pagedItem{Index: 4, Kind: "assistant", Text: strings.Repeat("log ", 3000)}
	corpus[200].Text = "needle survives the failure"
	host := &pagedTestHost{session: "s-1", revision: "9:9:9", corpus: corpus, inlineBytes: 4096, sourceError: true}
	m, r := pagedHostModel(t, host)

	r.find(&m, "needle")
	pagedScanAll(t, &m, r)
	if len(m.searchHits) != 1 || m.searchHits[0].block != 200 {
		t.Fatalf("a refused payload lost the readable hits: %#v", m.searchHits)
	}
	if !strings.Contains(m.status, "unreadable") {
		t.Fatalf("an unreadable payload was dropped silently: %q", m.status)
	}
}

// A copy pin reads the block it asked for, not the session behind it: the console's
// `next` continuation is only followed inside a span the frame asked for, so one
// pinned block cannot start a walk through the whole corpus and then be evicted by
// the pages that walk brought in.
func TestPagedCopyPinDoesNotWalkTheCorpus(t *testing.T) {
	m, r, host := pagedTranscriptModel(t, pagedUserCorpus(400))
	before := len(host.pageRequests())
	if _, err := r.copyHistory(&m, 1, 1); err == nil {
		t.Fatal("a released block was copied without loading it")
	}
	pagedDrive(t, &m, r, r.ensure(&m))
	if requests := host.pageRequests()[before:]; len(requests) > 2 {
		t.Fatalf("a one-block copy read %d pages instead of its own block", len(requests))
	}
	if _, held := r.resident[0]; !held {
		t.Fatal("the pinned block was not read")
	}
	text, err := r.copyHistory(&m, 1, 1)
	if err != nil {
		t.Fatalf("copy of the pinned block: %v", err)
	}
	if text != "> prompt 0" {
		t.Fatalf("copy text: %q", text)
	}
}

// A copy cannot win the one oversize working-set slot from the block on screen. It
// is reported instead of polling "not loaded yet" for as long as the session is
// open, and a refused copy leaves no pins behind.
func TestPagedCopyReportsAGiantBlockThatCannotGetTheSlot(t *testing.T) {
	corpus := pagedUserCorpus(120)
	corpus[100] = pagedItem{
		Index: 100, Kind: "tool", CallID: "c-1", Name: "bash", Status: "done",
		Result: mustPagedJSON(t, strings.Repeat("a", 2<<20)),
	}
	corpus[119] = pagedItem{
		Index: 119, Kind: "tool", CallID: "c-2", Name: "bash", Status: "done",
		Result: mustPagedJSON(t, strings.Repeat("b", 2<<20)),
	}
	host := &pagedTestHost{session: "s-1", revision: "4194304:1:1", corpus: corpus, inlineBytes: 1024}
	m := newModel()
	m.width, m.height = 80, 400
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	r.budget = 1 << 20
	if _, handled := r.apply(&m, commandResult{name: "transcript_index", payload: host.indexPayload(0, pagedIndexProbeLimit)}); !handled {
		t.Fatal("index reply not adopted")
	}
	m.jumpToTranscriptBlock(119)
	firstBlock, last := m.pagedVisibleBlocks()
	for at := firstBlock; at < last; at += pagedPageLimit {
		r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(at, pagedPageLimit)})
	}
	r.releaseInflight()
	pagedDrive(t, &m, r, r.ensure(&m))
	if r.resident[100].partial() || !r.resident[119].partial() {
		t.Fatal("fixture: the painted giant must hold the one oversize slot")
	}
	if _, err := r.copyHistory(&m, 120, 120); err == nil {
		t.Fatal("a copy of the queued giant was accepted as if it could be loaded")
	} else if !strings.Contains(err.Error(), "another large block") {
		t.Fatalf("the copy kept a silent retry loop: %v", err)
	}
	if len(r.pins) != 0 {
		t.Fatalf("a refused copy kept %d pins", len(r.pins))
	}
}

// A paged copy is synchronous: it needs the whole range resident at once, so the
// pin set it asks for must be bounded. A drag over the whole session is refused
// with a reason instead of pinning every block and loading the corpus.
func TestPagedCopyRefusesARangeItCannotPinWholesale(t *testing.T) {
	m, r, _ := pagedTranscriptModel(t, pagedUserCorpus(400))
	if _, err := r.copyHistory(&m, 1, 400); err == nil {
		t.Fatal("a drag over the whole session was accepted as a synchronous copy")
	} else if !strings.Contains(err.Error(), "copy a smaller range") {
		t.Fatalf("the refusal must be actionable: %v", err)
	}
	if len(r.pins) != 0 {
		t.Fatalf("a refused copy pinned %d blocks", len(r.pins))
	}
	// A bounded range still loads on retry, and a served copy releases its pins so
	// they cannot accumulate across selections.
	if _, err := r.copyHistory(&m, 1, 4); err == nil {
		t.Fatal("a released range must ask to be loaded first")
	} else if !strings.Contains(err.Error(), "not loaded yet") {
		t.Fatalf("unexpected copy error: %v", err)
	}
	pagedDrive(t, &m, r, r.ensure(&m))
	text, err := r.copyHistory(&m, 1, 4)
	if err != nil {
		t.Fatalf("copy of a bounded range: %v", err)
	}
	if !strings.Contains(text, "> prompt 0") || !strings.Contains(text, "> prompt 3") {
		t.Fatalf("copy text: %q", text)
	}
	if len(r.pins) != 0 {
		t.Fatalf("a served copy kept %d pins", len(r.pins))
	}
}

// A console that keeps failing one route must not be hammered every frame.
func TestPagedReplayStallsAfterRepeatedErrors(t *testing.T) {
	m, r, _ := pagedTranscriptModel(t, pagedUserCorpus(60))
	failing := json.RawMessage(`{"error":"transcript block index out of range"}`)
	for attempt := 0; attempt < pagedErrorBudget; attempt++ {
		if _, handled := r.apply(&m, commandResult{name: "transcript_page", payload: failing}); !handled {
			t.Fatal("error reply not consumed")
		}
	}
	if !r.stalled {
		t.Fatal("repeated failure did not stall on-demand loading")
	}
	if cmd := r.ensure(&m); cmd != nil {
		t.Fatal("a stalled document kept requesting pages")
	}
	if !strings.Contains(m.status, "transcript replay paused") {
		t.Fatalf("stall was silent: %q", m.status)
	}
	// The next index reply clears the stall.
	if _, handled := r.apply(&m, commandResult{name: "transcript_index", payload: mustPagedJSON(t, map[string]any{
		"session_id": "s-1", "revision": "1:1:1", "total": 60,
	})}); !handled {
		t.Fatal("index reply not adopted")
	}
	if r.stalled {
		t.Fatal("index reply did not clear the stall")
	}
}

func mustPagedJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("payload: %v", err)
	}
	return raw
}

// Scrolling the document is what moves the page window: the seam that keeps a
// sparse document on demand instead of on session size.
func TestPagedReplayScrollRequestsTheVisiblePagesOnly(t *testing.T) {
	m, r, host := pagedTranscriptModel(t, pagedUserCorpus(300))
	host.requests = nil
	r.inflight = nil
	m.scrollTranscript(-1_000_000)
	cmd := r.ensure(&m)
	if cmd == nil {
		t.Fatal("the oldest window is not resident and must be requested")
	}
	pagedResults(cmd)
	pages := host.pageRequests()
	if len(pages) == 0 {
		t.Fatal("no page requested after scrolling to the start")
	}
	if first := pagedArgInt(pages[0].args, "first", -1); first != 0 {
		t.Fatalf("scroll did not re-target the window: first=%d", first)
	}
	for _, page := range pages {
		if first := pagedArgInt(page.args, "first", -1); first > 60 {
			t.Fatalf("scrolled view still requested the tail page: %d", first)
		}
	}
	if cmd := r.ensure(&m); cmd != nil {
		t.Fatalf("a resident window kept asking for pages: %v", cmd)
	}
}

// Startup diagnostics are live UI facts: the first paged replay carries them
// after the history, a later replay retires them, like the classic path.
func TestPagedReplayKeepsStartupNoticesForTheInitialReplay(t *testing.T) {
	host := &pagedTestHost{session: "s-1", revision: "3:3:3", corpus: pagedUserCorpus(3)}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	m.protocolNotice("startup fixture warning")
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))
	last := len(m.transcript) - 1
	if m.blocks[last].Kind != "notice" || !strings.Contains(m.transcript[last], "startup fixture warning") {
		t.Fatalf("initial replay dropped the startup notice: %q %#v", m.transcript, m.blocks[last])
	}
	if !m.welcomeHidden {
		t.Fatal("restored conversation did not retire the welcome")
	}
	if last <= r.total-1 {
		t.Fatalf("the notice must sit after the paged history: total=%d notice=%d", r.total, last)
	}
	pagedDrive(t, &m, r, r.start(&m))
	for index, block := range m.blocks {
		if block.Kind == "notice" {
			t.Fatalf("a later paged replay carried a retired startup notice at %d", index)
		}
	}
	if len(m.transcript) != r.total {
		t.Fatalf("retired notice left a hole: %d blocks, %d slots", r.total, len(m.transcript))
	}
}

// A console may trim a page by bytes and not send `next` at all. The window must
// still converge instead of re-requesting the same chunk forever.
func TestPagedReplayConvergesOnTrimmedReplies(t *testing.T) {
	host := &pagedTestHost{session: "s-1", revision: "60:1:1", corpus: pagedUserCorpus(60), pageCap: 2, noNext: true}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	steps := pagedDrive(t, &m, r, r.start(&m))
	if steps > 80 {
		t.Fatalf("trimmed replies did not converge: %d replies", steps)
	}
	first, last := m.pagedVisibleBlocks()
	for block := first; block < last; block++ {
		if m.transcript[block] == "" {
			t.Fatalf("mounted block %d stayed empty after %d replies", block, steps)
		}
	}
	if cmd := r.ensure(&m); cmd != nil {
		t.Fatal("a resident window kept requesting pages")
	}
}

// A non-native host refuses the replay routes. The document must stop asking and
// hand the parent an explicit reason, so a fallback to the classic replay can be
// announced instead of silently swapping the source under the user.
func TestPagedReplayReportsUnavailableRoutesForExplicitFallback(t *testing.T) {
	host := &pagedRefusingHost{}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	cmd := r.start(&m)
	// Each frame the parent calls ensure; the console keeps refusing the route.
	for attempt := 0; attempt < pagedErrorBudget+2 && !r.failed() && cmd != nil; attempt++ {
		for _, result := range pagedResults(cmd) {
			if _, handled := r.apply(&m, result); !handled {
				t.Fatal("index reply not consumed")
			}
		}
		cmd = r.ensure(&m)
	}
	if !r.failed() {
		t.Fatal("a refusing console must be reported, not retried forever")
	}
	if !strings.Contains(r.failureReason(), "native-only") {
		t.Fatalf("failure reason lost the console message: %q", r.failureReason())
	}
	if cmd := r.ensure(&m); cmd != nil {
		t.Fatal("a failed replay kept requesting pages")
	}
}

type pagedRefusingHost struct{ testHost }

func (*pagedRefusingHost) Request(context.Context, string, any) (json.RawMessage, error) {
	return json.RawMessage(`{"error":"transcript_index is native-only (native_ui projection)"}`), nil
}

// The console patches a tool item when its ToolMessage appears on a later
// journal line, and that line can land in a later page: a re-delivered block
// with newer state must upgrade the resident copy instead of being skipped.
func TestPagedReplayAppliesToolResultPatchAcrossPages(t *testing.T) {
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: "run the tests"},
		{Index: 1, Kind: "tool", CallID: "c-1", Name: "bash", Status: "running"},
	}
	host := &pagedTestHost{session: "s-1", revision: "1:1:1", corpus: corpus}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))
	if m.blocks[1].State != "running" {
		t.Fatalf("first page: %#v", m.blocks[1])
	}
	// The resolved ToolMessage arrives in a later page of the same generation.
	host.corpus = []pagedItem{
		{Index: 0, Kind: "user", Text: "run the tests"},
		{Index: 1, Kind: "tool", CallID: "c-1", Name: "bash", Status: "done", Result: json.RawMessage(`"ok 12 tests"`)},
	}
	r.apply(&m, commandResult{name: "transcript_page", payload: host.pagePayload(0, 2)})
	if m.blocks[1].State != "succeeded" || !strings.Contains(m.blocks[1].Text, "ok 12 tests") {
		t.Fatalf("patched tool block: %#v", m.blocks[1])
	}
	if m.transcript[1] != "• bash" {
		t.Fatalf("patched tool source: %q", m.transcript[1])
	}
	found := false
	for _, source := range m.hiddenSearchSources {
		if source.block == 1 && strings.Contains(source.text, "ok 12 tests") {
			found = true
		}
	}
	if !found {
		t.Fatal("patched result is not searchable")
	}
	if r.bytes > r.residentBudget() {
		t.Fatalf("patch accounting overflowed: %d", r.bytes)
	}
}

// An empty journal is a valid session: the document stays empty, the welcome
// stays, and nothing is requested beyond the index probe.
func TestPagedReplayEmptySession(t *testing.T) {
	host := &pagedTestHost{session: "s-1", revision: "0:0:0"}
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))
	if r.total != 0 || len(m.transcript) != 0 || r.bytes != 0 {
		t.Fatalf("empty session: total=%d transcript=%d bytes=%d", r.total, len(m.transcript), r.bytes)
	}
	if m.welcomeHidden {
		t.Fatal("an empty session must keep the welcome")
	}
	if cmd := r.ensure(&m); cmd != nil {
		t.Fatalf("an empty session requested pages: %v", cmd)
	}
	if pages := host.pageRequests(); len(pages) != 0 {
		t.Fatalf("page requested for an empty session: %#v", pages)
	}
}

// A range read can fail for a legitimate reason (a tool result that has not been
// written yet). That must not stall pagination: the preview stays, the deferred
// payload is retired, and later pages keep loading.
func TestPagedReplaySourceFailureKeepsPreviewAndPaging(t *testing.T) {
	body := strings.Repeat("pending ", 2000)
	corpus := []pagedItem{
		{Index: 0, Kind: "tool", CallID: "c-1", Name: "bash", Status: "running"},
		{Index: 1, Kind: "user", Text: "wait for it"},
	}
	host := &pagedTestHost{session: "s-1", revision: "1:1:1", corpus: corpus}
	// The console refuses the payload of block 0: the tool result is not written.
	host.sourceError = true
	corpus[0].Text = body
	host.inlineBytes = 1024
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = "s-1"
	m.host = host
	r := newPagedReplay()
	pagedDrive(t, &m, r, r.start(&m))
	for attempt := 0; attempt < 4 && len(r.bodies) > 0; attempt++ {
		pagedDrive(t, &m, r, r.ensure(&m))
	}
	if r.failed() {
		t.Fatalf("a range failure stalled the document: %q", r.failureReason())
	}
	if len(m.transcript[0]) == 0 {
		t.Fatal("the preview was lost")
	}
	if len(m.transcript[0]) > len(body) {
		t.Fatalf("preview grew past the payload: %d", len(m.transcript[0]))
	}
	if m.transcript[1] != "> wait for it" {
		t.Fatalf("paging stopped after a range failure: %q", m.transcript[1])
	}
	if !strings.Contains(m.status, "body unavailable") {
		t.Fatalf("range failure was silent: %q", m.status)
	}
	if _, err := r.copyHistory(&m, 1, 1); err == nil {
		t.Fatal("a preview-only block must not be copied as if it were complete")
	}
}

// A revision is "<size>:<mtime>:<ns>": it proves the journal changed, never that
// it only grew. A rewrite (compaction, rewind, metadata refresh) can keep the
// block total while changing bodies, so a resident body of the retired
// generation must never stay on screen.
func TestPagedReplayRewriteDropsStaleBodies(t *testing.T) {
	corpus := pagedUserCorpus(4)
	corpus[2].Kind = "assistant"
	corpus[2].Text = "the old answer"
	host := &pagedTestHost{session: "s-1", revision: "4:1:1", corpus: corpus}
	m, r := pagedHostModel(t, host)
	if m.transcript[2] != "the old answer" {
		t.Fatalf("fixture: block 2 must be resident: %q", m.transcript)
	}
	// Same block total, different bodies: an in-place rewrite of the journal.
	corpus[2].Text = "the rewritten answer"
	corpus[3].Text = "a different prompt"
	host.revision = "4:1700000500:2"

	cmd := r.refresh(&m)
	if cmd == nil {
		t.Fatal("refresh must probe the index")
	}
	pagedDrive(t, &m, r, cmd)

	for block, source := range m.transcript {
		if strings.Contains(source, "the old answer") || strings.Contains(source, "> prompt 3") {
			t.Fatalf("block %d kept a body of the retired generation: %q", block, source)
		}
		if cell, ok := m.blocks[block]; ok && strings.Contains(cell.Text, "the old answer") {
			t.Fatalf("block %d cell kept a body of the retired generation: %#v", block, cell)
		}
	}
	if m.transcript[2] != "the rewritten answer" || m.transcript[3] != "> a different prompt" {
		t.Fatalf("the rewritten blocks were not re-read: %q %q", m.transcript[2], m.transcript[3])
	}
}

// pagedFrame drives host replies through the real Model.Update reducer, the way
// the Bubble Tea runtime does: only correlated replies are fed back, because UI
// timers are irrelevant to corpus delivery.
func pagedFrame(t *testing.T, m *model, cmd tea.Cmd, rounds int) int {
	t.Helper()
	pending := pagedResults(cmd)
	steps := 0
	for len(pending) > 0 {
		if steps++; steps > rounds {
			t.Fatalf("paged replay did not settle within %d frames", rounds)
		}
		var next []commandResult
		for _, result := range pending {
			updated, follow := m.Update(result)
			*m = updated.(model)
			next = append(next, pagedResults(follow)...)
		}
		pending = next
	}
	return steps
}

// pagedWiredModel attaches a paged session through the production reducer, so the
// seams below exercise model.go's routing and the frame-level ensure.
func pagedWiredModel(t *testing.T, host *pagedTestHost) model {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.host = host
	t.Cleanup(func() { m.Close() })
	next, attach := m.Update(commandResult{name: "runtime_state", payload: json.RawMessage(`{"session_id":"s-1","status":"ready"}`)})
	m = next.(model)
	// The attach returns the index probe; feeding it back runs the same reducer the
	// runtime does, including the frame-level ensure.
	pagedFrame(t, &m, attach, 60)
	if m.replay == nil || !m.replay.active() {
		t.Fatal("production attach did not start a paged replay")
	}
	return m
}
