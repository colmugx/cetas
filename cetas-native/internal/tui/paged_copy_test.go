package tui

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-native/internal/wire"
)

// pagedCopyRun executes one copy command the way the runtime would and returns
// the reply the parent reducer routes back.
func pagedCopyRun(t *testing.T, cmd tea.Cmd) pagedCopyResult {
	t.Helper()
	if cmd == nil {
		t.Fatal("the copy command is missing")
	}
	message := cmd()
	result, ok := message.(pagedCopyResult)
	if !ok {
		t.Fatalf("the copy command returned %#v", message)
	}
	return result
}

// pagedCopyClipboard resolves the command apply returns and reads the text it
// hands to the terminal clipboard (OSC52).
func pagedCopyClipboard(t *testing.T, cmd tea.Cmd) string {
	t.Helper()
	if cmd == nil {
		return ""
	}
	message := cmd()
	value := reflect.ValueOf(message)
	if value.Kind() != reflect.String {
		t.Fatalf("apply did not dispatch a clipboard write: %#v", message)
	}
	return value.String()
}

// pagedCopyJoined is the documented separator contract: empty blocks are
// skipped and everything else is joined by a blank line.
func pagedCopyJoined(blocks []string) string {
	kept := make([]string, 0, len(blocks))
	for _, block := range blocks {
		if block != "" {
			kept = append(kept, block)
		}
	}
	return strings.Join(kept, "\n\n")
}

// pagedCopyRequests is what one copy asked the console, without the requests the
// mounted window already made before it.
func pagedCopyRequests(console *pagedTestHost, from int, command string) []pagedTestRequest {
	var out []pagedTestRequest
	for _, request := range console.requests[from:] {
		if request.command == command {
			out = append(out, request)
		}
	}
	return out
}

// pagedCopyResidentSnapshot copies the resident bodies, so a test can prove a
// copy never stored, upgraded or released one.
func pagedCopyResidentSnapshot(r *pagedReplay) map[int]pagedItem {
	held := make(map[int]pagedItem, len(r.resident))
	for index, item := range r.resident {
		held[index] = item
	}
	return held
}

// pagedCopyModel attaches a paged document whose host may wrap the recording fake
// console, so a test can shape the replies the copy reads.
func pagedCopyModel(t *testing.T, host runtimeHost, console *pagedTestHost) (model, *pagedReplay) {
	t.Helper()
	m := newModel()
	m.width, m.height = 80, 24
	m.resize()
	m.session = console.session
	m.host = host
	r := newPagedReplay()
	// The parent allocates the document once; attach it before the index reply so
	// the model and the adapter agree on where the paged region ends.
	m.replay = r
	pagedDrive(t, &m, r, r.start(&m))
	return m, r
}

// A copy is one action, not a pin-and-retry loop: 400 blocks are read through the
// console's own bounded pages and the clipboard receives the whole selection in a
// single reply, with the replay cache, its resident bytes and its pins untouched.
func TestPagedCopyStreamsAWholeSelectionInOneAction(t *testing.T) {
	corpus := pagedUserCorpus(400)
	host := &pagedTestHost{session: "s-1", revision: "51200:1700000000:1", corpus: corpus, indexWindow: 400}
	m, r := pagedCopyModel(t, host, host)

	resident := pagedCopyResidentSnapshot(r)
	placeholders := append([]string(nil), m.transcript...)
	bytes := r.bytes
	pagesBefore := len(host.pageRequests())

	result := pagedCopyRun(t, m.pagedCopyRangeCommand(0, 399))
	if result.err != nil {
		t.Fatalf("copying 400 blocks: %v", result.err)
	}
	want := make([]string, 0, len(corpus))
	for _, item := range corpus {
		want = append(want, "> "+item.Text)
	}
	expected := pagedCopyJoined(want)
	if result.text != expected {
		t.Fatalf("copy text: %d bytes, want %d", len(result.text), len(expected))
	}
	if result.first != 0 || result.last != 399 || !result.paged || result.canceled {
		t.Fatalf("copy result identity: %#v", result)
	}

	requests := host.pageRequests()[pagesBefore:]
	if len(requests) != 13 {
		t.Fatalf("400 blocks took %d page requests, want 13 bounded pages", len(requests))
	}
	for _, request := range requests {
		if limit := pagedArgInt(request.args, "limit", 0); limit < 1 || limit > 32 {
			t.Fatalf("page limit %d is not the console's bounded page", limit)
		}
		if maxBytes := pagedArgInt(request.args, "max_bytes", 0); maxBytes != 1<<20 {
			t.Fatalf("page max_bytes %d, want 1 MiB", maxBytes)
		}
		if request.args["session_id"] != "s-1" || request.args["revision"] != host.revision {
			t.Fatalf("page request lost its generation: %#v", request.args)
		}
	}
	// Every useful request was internal to the command: nothing was pinned and no
	// page was stored, so a copy cannot grow the resident document.
	if len(r.pins) != 0 {
		t.Fatalf("a copy pinned %d blocks", len(r.pins))
	}
	if !reflect.DeepEqual(resident, pagedCopyResidentSnapshot(r)) || r.bytes != bytes {
		t.Fatal("the copy mutated the replay cache")
	}
	if !reflect.DeepEqual(placeholders, m.transcript) {
		t.Fatal("the copy mutated the document")
	}
	if r.revision != host.revision {
		t.Fatalf("the copy changed the document generation: %q", r.revision)
	}

	text := pagedCopyClipboard(t, m.applyPagedCopyResult(result))
	if text != expected {
		t.Fatalf("clipboard text: %d bytes, want %d", len(text), len(expected))
	}
	if !strings.Contains(m.status, "1–400") {
		t.Fatalf("the copy did not report its range: %q", m.status)
	}
	if m.err != "" {
		t.Fatalf("a successful copy reported an error: %q", m.err)
	}
}

// The formatter contract is the materialized document's: prompts keep "> ",
// answers stay raw, a tool contributes "• "+name only, a thought keeps its line
// count header - counted from the streamed payload, not from its preview - and a
// notice keeps "● ". The live tail past the paged region is copied from the
// model, never from the console.
func TestPagedCopyMatchesTheMaterializedFormatter(t *testing.T) {
	thought := strings.Repeat("thinking line\n", 1000)
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: "plot the data"},
		{Index: 1, Kind: "reasoning", Text: thought},
		{Index: 2, Kind: "assistant", Text: "here is the plot"},
		{Index: 3, Kind: "tool", CallID: "c-1", Name: "plot", Status: "done",
			Arguments: json.RawMessage(`{"path":"` + strings.Repeat("x", 200) + `"}`),
			Result:    mustPagedJSON(t, strings.Repeat("png bytes ", 4000))},
		{Index: 4, Kind: "notice", Text: "compacted earlier turns"},
	}
	console := &pagedTestHost{session: "s-1", revision: "8192:7:7", corpus: corpus, indexWindow: 400, inlineBytes: 4096}
	// A console that clamps range replies: the copy has to follow `next` and the
	// authoritative offset instead of assuming one reply is a whole payload.
	host := &pagedCopyChunkHost{pagedTestHost: console, chunk: 1024}
	m, r := pagedCopyModel(t, host, console)

	m.appendUser("live prompt")
	m.appendAssistant("live answer")
	last := m.transcriptBlockCount() - 1
	if last != 6 || r.total != 5 {
		t.Fatalf("fixture: last=%d paged=%d", last, r.total)
	}

	before := len(console.requests)
	result := pagedCopyRun(t, m.pagedCopyRangeCommand(0, last))
	if result.err != nil {
		t.Fatalf("mixed copy: %v", result.err)
	}
	expected := pagedCopyJoined([]string{
		"> plot the data",
		"💭 thought · 1001 lines",
		"here is the plot",
		"• plot",
		"● compacted earlier turns",
		"> live prompt",
		"live answer",
	})
	if result.text != expected {
		t.Fatalf("copy text:\n got %q\nwant %q", result.text, expected)
	}

	// A tool copy never reads the arguments or the result: they are collapsed
	// detail, not transcript source. Only the thought payload is streamed.
	offsets := map[int][]int{}
	for _, request := range pagedCopyRequests(console, before, "transcript_source") {
		field, _ := request.args["field"].(string)
		if field == "args" || field == "result" {
			t.Fatalf("a tool copy fetched its %q payload", field)
		}
		index := pagedArgInt(request.args, "index", -1)
		offsets[index] = append(offsets[index], pagedArgInt(request.args, "offset", -1))
		if length := pagedArgInt(request.args, "length", 0); length != 256<<10 {
			t.Fatalf("source chunk length %d, want 256 KiB", length)
		}
	}
	if len(offsets) != 1 {
		t.Fatalf("source payloads read: %#v", offsets)
	}
	chunks := offsets[1]
	if want := (len(thought) + 1023) / 1024; len(chunks) != want {
		t.Fatalf("the clamped payload took %d chunks, want %d: %#v", len(chunks), want, chunks)
	}
	for at, offset := range chunks {
		if offset != at*1024 {
			t.Fatalf("chunk offsets did not follow the console: %#v", chunks)
		}
	}
	text := pagedCopyClipboard(t, m.applyPagedCopyResult(result))
	if text != expected {
		t.Fatalf("clipboard text:\n got %q\nwant %q", text, expected)
	}
}

// A selection is all or nothing: a payload that would blow the clipboard limit
// is refused while streaming, so the copy never holds the giant body whole and
// never leaves a truncated clipboard behind.
func TestPagedCopyRefusesPayloadsPastTheClipboardLimit(t *testing.T) {
	giant := strings.Repeat("a", 3<<20)
	corpus := []pagedItem{
		{Index: 0, Kind: "user", Text: giant},
		{Index: 1, Kind: "assistant", Text: giant},
	}
	console := &pagedTestHost{session: "s-1", revision: "6291456:1:1", corpus: corpus, indexWindow: 400, inlineBytes: 4096}
	m, _ := pagedCopyModel(t, console, console)

	before := len(console.requests)
	result := pagedCopyRun(t, m.pagedCopyRangeCommand(0, 1))
	if result.err == nil || !strings.Contains(result.err.Error(), "4 MB limit") {
		t.Fatalf("an oversized selection was accepted: %v", result.err)
	}
	if result.text != "" {
		t.Fatalf("a refused copy produced %d bytes of partial text", len(result.text))
	}
	if cmd := m.applyPagedCopyResult(result); cmd != nil {
		t.Fatal("a refused copy wrote a clipboard")
	}
	if !strings.Contains(m.err, "4 MB limit") {
		t.Fatalf("the refusal was silent: %q", m.err)
	}
	requested := 0
	for _, request := range pagedCopyRequests(console, before, "transcript_source") {
		length := pagedArgInt(request.args, "length", 0)
		if length > 256<<10 {
			t.Fatalf("source chunk length %d is not bounded", length)
		}
		requested += length
	}
	if requested >= 2*len(giant) {
		t.Fatalf("the copy read %d bytes of a %d byte selection before refusing it", requested, 2*len(giant))
	}
}

// pagedCopyChunkHost clamps transcript_source ranges the way a console under load
// might, so the copy has to use the authoritative offset and `next` instead of
// assuming one reply carries the whole payload.
type pagedCopyChunkHost struct {
	*pagedTestHost
	chunk int
}

func (h *pagedCopyChunkHost) Request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	payload, err := h.pagedTestHost.Request(ctx, command, args)
	if err != nil || command != "transcript_source" || h.chunk <= 0 {
		return payload, err
	}
	var reply pagedSourceReply
	if json.Unmarshal(payload, &reply) != nil || len(reply.Data) <= h.chunk {
		return payload, nil
	}
	reply.Data = reply.Data[:h.chunk]
	reply.Length = len(reply.Data)
	if next := reply.Offset + len(reply.Data); next < reply.TotalBytes {
		reply.Next = &next
	} else {
		reply.Next = nil
	}
	return json.Marshal(reply)
}

// pagedCopyCancelHost retires the copy from inside one of its own requests, the
// way a user who drags a new selection does while the previous copy is reading.
type pagedCopyCancelHost struct {
	*pagedTestHost
	after  int
	calls  int
	cancel func()
}

func (h *pagedCopyCancelHost) Request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	h.calls++
	if h.cancel != nil && h.after > 0 && h.calls == h.after {
		h.cancel()
	}
	return h.pagedTestHost.Request(ctx, command, args)
}

// A superseded copy stops reading and its late reply is dropped: another copy,
// another generation, another session or a rewritten journal all own the
// document now, and none of them may be overwritten by the retired text.
func TestPagedCopyDropsSupersededResults(t *testing.T) {
	console := &pagedTestHost{session: "s-1", revision: "20480:3:3", corpus: pagedUserCorpus(200), indexWindow: 400}
	host := &pagedCopyCancelHost{pagedTestHost: console}
	m, _ := pagedCopyModel(t, host, console)
	host.cancel = func() { m.cancelPagedCopy() }

	stale := m.pagedCopyRangeCommand(0, 199)
	superseding := m.pagedCopyRangeCommand(0, 199)
	retired := pagedCopyRun(t, stale)
	if !retired.canceled || retired.text != "" {
		t.Fatalf("a superseded copy kept reading: %#v", retired)
	}
	if cmd := m.applyPagedCopyResult(retired); cmd != nil {
		t.Fatal("a superseded copy wrote a clipboard")
	}
	live := pagedCopyRun(t, superseding)
	if live.err != nil {
		t.Fatalf("the superseding copy failed: %v", live.err)
	}
	if text := pagedCopyClipboard(t, m.applyPagedCopyResult(live)); !strings.Contains(text, "> prompt 199") {
		t.Fatalf("clipboard text: %q", text)
	}

	// Cancelled in flight: the request that already reached the console is the
	// last one, and no error reaches the user.
	host.calls, host.after = 0, 3
	interrupted := pagedCopyRun(t, m.pagedCopyRangeCommand(0, 199))
	if !interrupted.canceled || interrupted.text != "" {
		t.Fatalf("an interrupted copy kept its text: %#v", interrupted)
	}
	if cmd := m.applyPagedCopyResult(interrupted); cmd != nil {
		t.Fatal("an interrupted copy wrote a clipboard")
	}
	if m.err != "" {
		t.Fatalf("cancellation was reported as an error: %q", m.err)
	}

	// A stale reply of any other kind is dropped without a clipboard write.
	done := pagedCopyRun(t, m.pagedCopyRangeCommand(0, 3))
	if done.err != nil {
		t.Fatalf("copy of the live window: %v", done.err)
	}
	m.copyGeneration++
	if cmd := m.applyPagedCopyResult(done); cmd != nil {
		t.Fatal("a reply of a retired copy generation wrote a clipboard")
	}
	done = pagedCopyRun(t, m.pagedCopyRangeCommand(0, 3))
	m.session = "s-2"
	if cmd := m.applyPagedCopyResult(done); cmd != nil {
		t.Fatal("a reply of another session wrote a clipboard")
	}
	m.session = "s-1"
	done = pagedCopyRun(t, m.pagedCopyRangeCommand(0, 3))
	m.replayGeneration++
	if cmd := m.applyPagedCopyResult(done); cmd != nil {
		t.Fatal("a reply of a restarted replay wrote a clipboard")
	}
	m.replayGeneration--
	done = pagedCopyRun(t, m.pagedCopyRangeCommand(0, 3))
	m.replay.revision = "20480:9:9"
	m.status = ""
	if cmd := m.applyPagedCopyResult(done); cmd != nil {
		t.Fatal("a reply of a rewritten journal wrote a clipboard")
	}
	if !strings.Contains(m.status, "changed while copying") {
		t.Fatalf("a rewritten journal was not reported: %q", m.status)
	}
}

// pagedCopyScriptHost answers the copy routes with ready-made payloads, so a test
// can present one protocol violation at a time.
type pagedCopyScriptHost struct {
	page   string
	source string
}

func (h *pagedCopyScriptHost) Request(_ context.Context, command string, _ any) (json.RawMessage, error) {
	switch command {
	case "transcript_page":
		return json.RawMessage(h.page), nil
	case "transcript_source":
		return json.RawMessage(h.source), nil
	}
	return json.RawMessage(`{}`), nil
}

func (*pagedCopyScriptHost) Events() <-chan wire.Event   { return nil }
func (*pagedCopyScriptHost) Errors() <-chan error        { return nil }
func (*pagedCopyScriptHost) Close(context.Context) error { return nil }

// The command captures its range: an Update that runs while the copy is in
// flight cannot change what it reads, so the clipboard is what the user selected
// and not what a settling turn turned it into.
func TestPagedCopyCapturesTheLiveTailAtCommandTime(t *testing.T) {
	console := &pagedTestHost{session: "s-1", revision: "10:1:1", corpus: pagedUserCorpus(2), indexWindow: 400}
	m, r := pagedCopyModel(t, console, console)
	m.appendAssistant("settled answer")
	cmd := m.pagedCopyRangeCommand(r.total, m.transcriptBlockCount()-1)

	m.transcript[r.total] = "rewritten while copying"
	m.appendAssistant("a later turn")

	result := pagedCopyRun(t, cmd)
	if result.err != nil {
		t.Fatalf("live copy: %v", result.err)
	}
	if result.text != "settled answer" {
		t.Fatalf("the copy read the mutated document: %q", result.text)
	}
}
