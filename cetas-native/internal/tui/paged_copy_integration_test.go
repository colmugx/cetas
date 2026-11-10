package tui

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// Inspect the command's real clipboard message, not a second formatter or a
// synchronous cache read. Non-clipboard host/timer messages are not applied.
func copiedTextFromCommand(cmd tea.Cmd) (string, bool) {
	if cmd == nil {
		return "", false
	}
	message := cmd()
	if batch, ok := message.(tea.BatchMsg); ok {
		for _, child := range batch {
			if text, found := copiedTextFromCommand(child); found {
				return text, true
			}
		}
		return "", false
	}
	if reflect.TypeOf(message) == reflect.TypeOf(tea.SetClipboard("")()) {
		return reflect.ValueOf(message).String(), true
	}
	return "", false
}

func TestPagedCopyHistoryCompletesFromOneActionBeyond64Entries(t *testing.T) {
	m, replay, _ := pagedTranscriptModel(t, pagedUserCorpus(400))
	defer m.Close()
	m.replay = replay
	cmd := m.command("/copyhistory 1 400")
	if cmd == nil {
		t.Fatalf("copy was refused or required another action: %s", m.err)
	}
	result := cmd()
	next, completion := m.Update(result)
	m = next.(model)
	text, ok := copiedTextFromCommand(completion)
	if !ok {
		t.Fatalf("one copy action never produced a clipboard command: %s", m.err)
	}
	want := make([]string, 400)
	for i := range want {
		want[i] = fmt.Sprintf("> prompt %d", i)
	}
	if text != strings.Join(want, "\n\n") {
		t.Fatal("copy omitted history or changed its original source")
	}
}

func TestPagedMouseRangeCopiesAfterReleaseWithoutRetry(t *testing.T) {
	m, replay, host := pagedTranscriptModel(t, pagedUserCorpus(2))
	defer m.Close()
	m.replay = replay
	pagedLoadAll(t, &m, replay, host)
	m.reflow()
	m.virtualScroll.top = 0
	m.virtualScroll.followEnd = false
	m.refreshTranscript()
	row := m.virtualScroll.prefix(1)
	m.document.selection = transcriptSelection{active: true,
		anchor: transcriptPoint{row: 0, col: 0}, focus: transcriptPoint{row: row, col: 1}}
	var copied string
	m.document.onCopy = func(text string) tea.Cmd { copied = text; return nil }
	region := m.transcriptRegion()
	cmd, handled := m.transcriptMouseRelease(1, region.Y+row)
	if !handled || cmd == nil || m.document.selection.active || copied != "" {
		t.Fatal("release did not start an asynchronous copy and clear the highlight")
	}
	next, _ := m.Update(cmd())
	m = next.(model)
	if copied != "> prompt 0\n\n> prompt 1" {
		t.Fatalf("release required retry or bypassed the clipboard hook: %q / %s", copied, m.err)
	}
}

func TestPagedCopyNeverAcceptsGapsOrPrematureSourceEnd(t *testing.T) {
	const refPage = `{"session_id":"s","revision":"R","first":0,"total":1,"items":[{"index":0,"kind":"assistant","textRef":{"index":0,"field":"text","offset":0,"length":4}}],"next":null}`
	for _, tc := range []struct {
		name, page, source string
		count              int
	}{
		{"page gap", `{"session_id":"s","revision":"R","first":0,"total":2,"items":[{"index":1,"kind":"user","text":"second"}],"next":null}`, "", 2},
		{"page continuation gap", `{"session_id":"s","revision":"R","first":0,"total":2,"items":[{"index":0,"kind":"user","text":"first"}],"next":2}`, "", 2},
		{"source premature end", refPage, `{"session_id":"s","revision":"R","index":0,"field":"text","offset":0,"length":1,"total_bytes":4,"data":"x","next":null}`, 1},
		{"source offset gap", refPage, `{"session_id":"s","revision":"R","index":0,"field":"text","offset":1,"length":3,"total_bytes":4,"data":"xyz","next":null}`, 1},
		{"source length mismatch", refPage, `{"session_id":"s","revision":"R","index":0,"field":"text","offset":0,"length":4,"total_bytes":4,"data":"x","next":null}`, 1},
		{"source continuation gap", refPage, `{"session_id":"s","revision":"R","index":0,"field":"text","offset":0,"length":1,"total_bytes":4,"data":"x","next":3}`, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host := &pagedCopyScriptHost{page: tc.page, source: tc.source}
			request := pagedCopyRequest{host: host, session: "s", revision: "R", first: 0, last: tc.count - 1, end: tc.count, pagedEnd: tc.count}
			result := request.run(context.Background())
			if result.err == nil || result.text != "" {
				t.Fatalf("invalid protocol silently copied a partial selection: %#v", result)
			}
		})
	}
}
