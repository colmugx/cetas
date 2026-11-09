package tui

// The paged copy in paged_transcript.go (copyRange) is a display path: it pins
// the selection, refuses ranges wider than pagedPinLimit blocks and asks the user
// to retry once the pages are resident. That contract cannot serve a drag over a
// long session, which is the selection a user actually makes. This file is the
// production copy: one asynchronous command reads the console's own bounded
// routes (transcript_page / transcript_source) and builds the clipboard text
// itself, so a selection of any length copies in one action, nothing is pinned,
// and the replay cache, its resident budget and its bodies are never touched.
//
// The formatting contract is exactly the materialized document's
// (transcriptSourceAt): a prompt is "> "+text, an answer is raw source, a tool is
// "• "+name and nothing else (its arguments and result are collapsed tool
// detail, not copy source), a thought is its existing header with the line count
// of the whole payload, a notice is "● "+text, empty blocks are skipped, and
// blocks are joined with a blank line.
//
// The parent reducer owns three seams:
//
//	// 1. start a copy instead of the synchronous copySourceRange/copyHistory
//	//    whenever the document may be paged (0-based, inclusive, live tail too)
//	if cmd := m.pagedCopyRangeCommand(first, last); cmd != nil {
//		return cmd
//	}
//
//	// 2. route the reply, before the generic commandResult handling
//	case pagedCopyResult:
//		return m, m.applyPagedCopyResult(msg)
//
//	// 3. retire the in-flight read on session switch, rewind and quit
//	m.cancelPagedCopy()
//
// A reply that is superseded - another copy, another session, a restarted
// replay, a rewritten journal - is dropped without a clipboard write and
// without an error the user has to read, because the newer state owns it.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// pagedCopyTooLarge is the refusal copySourceBlocks already makes for a
// selection past maxTranscriptCopyChars: a copy is all or nothing, so an
// oversized selection never truncates silently.
var pagedCopyTooLarge = errors.New("selected transcript text exceeds 4 MB limit")

// pagedCopyChanged reports a journal that moved while the copy was reading it.
// The block indexes the copy holds belong to the retired generation, so the
// selection has to be made again against what is on screen now.
var pagedCopyChanged = errors.New("the transcript changed while copying; copy the selection again")

// pagedCopyResult is the outcome of one asynchronous paged copy. It carries the
// generation it was produced for, so a late reply can never write a clipboard
// over a document it no longer describes.
type pagedCopyResult struct {
	session          string
	revision         string
	replayGeneration uint64
	copyGeneration   uint64
	first, last      int
	paged            bool // the copy read the console, so `revision` gates it
	text             string
	err              error
	canceled         bool
}

// pagedCopyRangeCommand starts the asynchronous copy of an inclusive, 0-based
// block range. The live tail past the paged region is materialized in the model,
// so it is captured here as source and never requested from the console.
//
// The returned command is the only thing the copy needs: it captures the host,
// the session, the journal revision, the range and the live sources at this
// instant, so an Update that runs while it is in flight cannot change what it
// reads.
func (m *model) pagedCopyRangeCommand(first, last int) tea.Cmd {
	if m == nil {
		return nil
	}
	if first < 0 || last < first || last >= m.transcriptBlockCount() {
		m.err = "invalid transcript copy range"
		return nil
	}
	request := &pagedCopyRequest{
		host:             m.host,
		session:          m.session,
		replayGeneration: m.replayGeneration,
		copyGeneration:   m.copyGeneration + 1,
		first:            first,
		last:             last,
		end:              last + 1,
		pagedEnd:         m.pagedCopyBoundary(),
	}
	if m.replay != nil {
		request.revision = m.replay.revision
	}
	for at := max(first, request.pagedEnd); at <= last; at++ {
		// Immutable by construction: the strings of the live tail are copied now,
		// so a stream that settles mid-copy cannot rewrite them.
		request.live = append(request.live, m.transcriptSourceAt(at))
	}
	m.copyGeneration = request.copyGeneration
	if m.copyCancel != nil {
		// A newer selection supersedes the older read: it must stop spending
		// requests on a range the user is no longer copying.
		m.copyCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.copyCancel = cancel
	m.status = fmt.Sprintf("copying transcript entries %d–%d…", first+1, last+1)
	return func() tea.Msg {
		defer cancel()
		return request.run(ctx)
	}
}

// applyPagedCopyResult consumes the reply of pagedCopyRangeCommand. A reply of a
// retired generation is dropped silently; a live one either sets the clipboard
// to the complete text or reports why the selection could not be copied.
func (m *model) applyPagedCopyResult(result pagedCopyResult) tea.Cmd {
	if m == nil {
		return nil
	}
	if result.canceled || errors.Is(result.err, context.Canceled) {
		return nil // a superseded copy is not a failure the user has to read
	}
	if result.session != m.session || result.replayGeneration != m.replayGeneration || result.copyGeneration != m.copyGeneration {
		return nil // another session, another replay, or a newer copy: drop it
	}
	m.copyCancel = nil // This generation has settled, including an error reply.
	if result.paged && m.replay != nil && m.replay.revision != result.revision {
		// The journal was rewritten after the copy started: its block indexes are
		// no longer the ones on screen, so the text is not the user's selection.
		m.status = pagedCopyChanged.Error()
		return nil
	}
	if result.err != nil {
		m.status = ""
		m.err = result.err.Error()
		return nil
	}
	if result.text == "" {
		m.status = ""
		m.err = "selected transcript entries have no text"
		return nil
	}
	m.status = fmt.Sprintf("sent transcript entries %d–%d to terminal clipboard", result.first+1, result.last+1)
	if m.document.onCopy != nil {
		return m.document.onCopy(result.text)
	}
	return tea.SetClipboard(result.text)
}

// cancelPagedCopy retires the copy in flight. The generation bump is what makes
// a reply that still lands later harmless; the context is what stops the
// requests the copy would otherwise keep issuing.
func (m *model) cancelPagedCopy() {
	if m == nil {
		return
	}
	m.copyGeneration++
	if m.copyCancel != nil {
		m.copyCancel()
		m.copyCancel = nil
	}
	if strings.HasPrefix(m.status, "copying transcript entries") {
		m.status = ""
	}
}

// pagedCopyBoundary is the first block index that is a live append rather than a
// paged console block. Everything before it must be read from the console; the
// blocks after it are already materialized in the model.
func (m *model) pagedCopyBoundary() int {
	if m == nil || m.replay == nil || !m.replay.indexed {
		return 0
	}
	return min(max(0, m.replay.total), len(m.transcript))
}

// pagedCopyRequest is the immutable capture of one copy.
type pagedCopyRequest struct {
	host             runtimeHost
	session          string
	revision         string
	replayGeneration uint64
	copyGeneration   uint64
	first, last      int
	end              int      // first block past the range
	pagedEnd         int      // first live append; blocks from here are captured
	live             []string // copy source of the live tail, in document order
}

// run produces the result the command returns. A canceled context is reported as
// cancellation, never as an error: the copy was superseded, not broken.
func (request *pagedCopyRequest) run(ctx context.Context) pagedCopyResult {
	result := pagedCopyResult{
		session:          request.session,
		revision:         request.revision,
		replayGeneration: request.replayGeneration,
		copyGeneration:   request.copyGeneration,
		first:            request.first,
		last:             request.last,
		paged:            request.pagedEnd > request.first,
	}
	out := &pagedCopyBuffer{limit: maxTranscriptCopyChars}
	err := request.copy(ctx, out)
	if ctx.Err() != nil {
		result.canceled = true
		return result
	}
	if err != nil {
		result.err = err
		return result
	}
	result.text = out.String()
	return result
}

// copy reads the paged region page by page, then appends the captured live tail.
// Nothing here is bounded by a block count: the only bounds are the console's own
// page/source chunk sizes and the existing clipboard size limit.
func (request *pagedCopyRequest) copy(ctx context.Context, out *pagedCopyBuffer) error {
	for at := request.first; at < min(request.end, request.pagedEnd); {
		if err := ctx.Err(); err != nil {
			return err
		}
		next, err := request.copyPage(ctx, at, out)
		if err != nil {
			return err
		}
		at = next
	}
	for _, source := range request.live {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := out.write(source); err != nil {
			return err
		}
		out.endBlock()
	}
	return nil
}

// copyPage materializes one bounded page and copies the blocks it covers,
// returning the first block the next request must ask for.
func (request *pagedCopyRequest) copyPage(ctx context.Context, at int, out *pagedCopyBuffer) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	stop := min(request.end, request.pagedEnd)
	limit := min(pagedPageLimit, stop-at)
	payload, err := request.call(ctx, "transcript_page", map[string]any{
		"session_id": request.session,
		"revision":   request.revision,
		"first":      at,
		"limit":      limit,
		"max_bytes":  pagedPageMaxBytes,
	})
	if err != nil {
		return 0, err
	}
	reply, err := request.decodePage(payload, at)
	if err != nil {
		return 0, err
	}
	next := at
	for _, raw := range reply.Items {
		var item pagedItem
		if err := json.Unmarshal(raw, &item); err != nil {
			// A block the copy cannot read must not be skipped: the clipboard would
			// silently hold a hole where the user's selection was.
			return 0, fmt.Errorf("invalid transcript page: block %d is not a JSON object", at+1)
		}
		if item.Index != next || item.Index >= stop {
			return 0, fmt.Errorf("transcript_page left a gap at block %d", next+1)
		}
		next = item.Index + 1
		if err := request.copyItem(ctx, item, out); err != nil {
			return 0, err
		}
		out.endBlock()
	}
	if continuation := reply.Next; continuation != nil && *continuation != next {
		return 0, fmt.Errorf("transcript_page continuation skipped block %d", next+1)
	}
	if next <= at {
		return 0, fmt.Errorf("transcript page returned no block from %d on", at+1)
	}
	return next, nil
}

// copyItem writes the clipboard source of one console block using the formatter
// of the materialized document.
func (request *pagedCopyRequest) copyItem(ctx context.Context, item pagedItem, out *pagedCopyBuffer) error {
	switch normalizePagedKind(item.Kind) {
	case "user":
		return request.copyText(ctx, item, "> ", out)
	case "assistant", "":
		return request.copyText(ctx, item, "", out)
	case "reasoning":
		return request.copyReasoning(ctx, item, out)
	case "tool":
		// The row is the tool's name. Its arguments and result are collapsed detail
		// the classic copy never returns, so they are never fetched here either.
		return out.write("• " + item.Name)
	default:
		return request.copyText(ctx, item, "● ", out)
	}
}

// copyText writes a block whose source is its text payload. An empty block
// contributes nothing at all, not even a separator.
func (request *pagedCopyRequest) copyText(ctx context.Context, item pagedItem, prefix string, out *pagedCopyBuffer) error {
	text, ref := pagedCopyPayload(item.Text, item.TextRef)
	if text == "" && ref == nil {
		return nil
	}
	if err := out.write(prefix + text); err != nil {
		return err
	}
	if ref == nil {
		return nil
	}
	return request.stream(ctx, item.Index, ref, out.write)
}

// copyReasoning writes the existing thinking header. The line count describes the
// whole payload, so a giant thought is streamed and counted chunk by chunk
// instead of being retained to be measured.
func (request *pagedCopyRequest) copyReasoning(ctx context.Context, item pagedItem, out *pagedCopyBuffer) error {
	text, ref := pagedCopyPayload(item.Text, item.TextRef)
	if text == "" && ref == nil {
		return nil
	}
	lines := lenLines(text)
	if ref != nil {
		read := 0
		if err := request.stream(ctx, item.Index, ref, func(chunk string) error {
			read += strings.Count(chunk, "\n")
			return nil
		}); err != nil {
			return err
		}
		lines = 1 + read
	}
	return out.write(fmt.Sprintf("💭 thought · %d lines", lines))
}

// pagedCopyPayload splits a block's text into the inline source and, when the
// console only sent a preview, the ref whose payload still has to be streamed.
// A ref is the whole payload, so the preview is never copied as if it were one.
func pagedCopyPayload(text string, ref *pagedRef) (string, *pagedRef) {
	if ref != nil && ref.Length > 0 {
		return "", ref
	}
	return text, nil
}

// stream reads one deferred payload in bounded range chunks. The chunks are
// handed to the sink as they arrive, so a payload larger than the clipboard limit
// is refused while streaming instead of being held whole first.
func (request *pagedCopyRequest) stream(ctx context.Context, index int, ref *pagedRef, sink func(string) error) error {
	field := strings.TrimSpace(ref.Field)
	if field == "" {
		field = "text" // the console's own default payload name
	}
	total := ref.Length
	// A ref describes the whole payload, replacing the inline preview. Its
	// preview offset must never turn a complete source copy into a suffix.
	offset := 0
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		payload, err := request.call(ctx, "transcript_source", map[string]any{
			"session_id": request.session,
			"revision":   request.revision,
			"index":      index,
			"field":      field,
			"offset":     offset,
			"length":     pagedSourceChunkBytes,
		})
		if err != nil {
			return err
		}
		reply, err := request.decodeSource(payload, index, field, offset)
		if err != nil {
			return err
		}
		if reply.TotalBytes != total || reply.Offset != offset || reply.Length != len(reply.Data) {
			return fmt.Errorf("transcript_source returned an inconsistent range at block %d", index+1)
		}
		read := reply.Offset + reply.Length
		if read > total || (reply.Next == nil && read != total) ||
			(reply.Next != nil && (*reply.Next != read || read >= total)) {
			return fmt.Errorf("transcript_source returned an incomplete range at block %d", index+1)
		}
		if reply.Data != "" {
			if err := sink(reply.Data); err != nil {
				return err
			}
		}
		if reply.Next == nil {
			return nil
		}
		if read <= offset {
			return fmt.Errorf("transcript_source returned no data from offset %d of block %d", offset, index+1)
		}
		offset = *reply.Next
	}
}

// call issues one bounded console request. The context is checked around the
// host call, so a superseded copy stops even against a host that ignores it.
func (request *pagedCopyRequest) call(ctx context.Context, command string, args map[string]any) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if request.host == nil {
		return nil, errors.New("transcript copy needs a console connection")
	}
	readCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	payload, err := request.host.Request(readCtx, command, args)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("%s: %w", command, err)
	}
	return payload, nil
}

// decodePage validates one page reply: its session, its journal generation and
// the block it claims to start at. A reply that fails any of these is refused
// instead of being spliced into the clipboard.
func (request *pagedCopyRequest) decodePage(payload json.RawMessage, at int) (pagedReply, error) {
	if message, _, _, ok := pagedError(payload); ok {
		return pagedReply{}, request.protocolError("transcript_page", message)
	}
	reply, ok := decodePagedReply(payload)
	if !ok {
		return pagedReply{}, errors.New("invalid transcript page: reply is not a JSON object")
	}
	if reply.SessionID != "" && request.session != "" && reply.SessionID != request.session {
		return pagedReply{}, errors.New("transcript_page answered for another session")
	}
	if request.revision != "" && reply.Revision != "" && reply.Revision != request.revision {
		return pagedReply{}, pagedCopyChanged
	}
	if reply.First != nil && *reply.First != at {
		return pagedReply{}, fmt.Errorf("transcript_page answered from block %d instead of %d", *reply.First+1, at+1)
	}
	return reply, nil
}

// decodeSource validates one range reply: the session, the generation, the block,
// the payload field and the offset it re-anchored to.
func (request *pagedCopyRequest) decodeSource(payload json.RawMessage, index int, field string, offset int) (pagedSourceReply, error) {
	if message, _, _, ok := pagedError(payload); ok {
		return pagedSourceReply{}, request.protocolError("transcript_source", message)
	}
	var reply pagedSourceReply
	if err := json.Unmarshal(payload, &reply); err != nil {
		return pagedSourceReply{}, errors.New("invalid transcript source: reply is not a JSON object")
	}
	if reply.SessionID != "" && request.session != "" && reply.SessionID != request.session {
		return pagedSourceReply{}, errors.New("transcript_source answered for another session")
	}
	if request.revision != "" && reply.Revision != "" && reply.Revision != request.revision {
		return pagedSourceReply{}, pagedCopyChanged
	}
	answered := index
	if reply.Index != nil {
		answered = *reply.Index
	}
	if reply.Index == nil || *reply.Index != index {
		return pagedSourceReply{}, fmt.Errorf("transcript_source answered for block %d instead of %d", answered+1, index+1)
	}
	if reply.Field != "" && reply.Field != "auto" && field != "" && reply.Field != field {
		// transcript_source resolves one payload per read. Appending the arguments
		// (or the result) to the text being copied would splice the wrong body in.
		return pagedSourceReply{}, fmt.Errorf("transcript_source answered the %q payload instead of %q at block %d", reply.Field, field, index+1)
	}
	if reply.Offset < offset {
		return pagedSourceReply{}, fmt.Errorf("transcript_source answered offset %d instead of %d at block %d", reply.Offset, offset, index+1)
	}
	return reply, nil
}

// protocolError turns a console error envelope into an actionable copy error.
func (request *pagedCopyRequest) protocolError(command, message string) error {
	if message == "stale transcript revision" {
		// Total >= selected end is not append proof: a same-size rewrite or a
		// compacted/replaced journal can preserve its count but change sources.
		// Until the wire offers a stable snapshot/verified prefix, abort rather
		// than mixing revisions in one clipboard (even for an ordinary append).
		return pagedCopyChanged
	}
	return fmt.Errorf("%s: %s", command, message)
}

// pagedCopyBuffer accumulates the clipboard text of one copy. It enforces the
// existing maxTranscriptCopyChars limit while streaming, and it owns the blank
// line between blocks, so a skipped or empty block never leaves a separator
// behind.
type pagedCopyBuffer struct {
	text    strings.Builder
	limit   int
	blocks  int
	open    bool
	needSep bool
}

// write appends source to the block being accumulated, opening it first if this
// is its first text.
func (b *pagedCopyBuffer) write(source string) error {
	if source == "" {
		return nil
	}
	if !b.open {
		b.open = true
		b.blocks++
		b.needSep = b.blocks > 1
	}
	if b.needSep {
		if err := b.raw("\n\n"); err != nil {
			return err
		}
		b.needSep = false
	}
	return b.raw(source)
}

// raw is the size-checked write: the whole selection is bound by the same limit
// copySourceBlocks applies, and an oversized one is refused as a whole.
func (b *pagedCopyBuffer) raw(source string) error {
	if b.text.Len()+len(source) > b.limit {
		return pagedCopyTooLarge
	}
	b.text.WriteString(source)
	return nil
}

// endBlock closes the block being accumulated.
func (b *pagedCopyBuffer) endBlock() {
	b.open = false
	b.needSep = false
}

// String returns the complete clipboard text.
func (b *pagedCopyBuffer) String() string { return b.text.String() }
