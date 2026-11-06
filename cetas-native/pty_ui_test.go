package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-native/harness"
)

// This test runs in a real PTY from tools/pty_ui_smoke.py. It uses the actual
// Bubble Tea program and key decoder, while replacing only the provider-side
// harness with an event script. It is deliberately not a fake Provider test.
type scriptedPTYHost struct {
	events chan harness.Event
	mu sync.Mutex
	replies []ptyReply
}

type ptyReply struct {
	RequestID string `json:"request_id"`
	Selected *int `json:"selected,omitempty"`
	Text *string `json:"text,omitempty"`
	Cancelled bool `json:"cancelled,omitempty"`
}

func newScriptedPTYHost() *scriptedPTYHost {
	h:=&scriptedPTYHost{events:make(chan harness.Event,32)}
	// The second and third requests arrive while approval is still open.
	// They must remain FIFO regardless of terminal redraws.
	h.emit(`{"type":"ui.request","session_id":"pty-session","request_id":"u-1","kind":"select","prompt":"Approve shell command?","options":["Allow once","Allow for session","Allow all shell commands","Deny"]}`)
	h.emit(`{"type":"ui.request","session_id":"pty-session","request_id":"u-2","kind":"input","prompt":"CJK question: enter a response"}`)
	h.emit(`{"type":"ui.request","session_id":"pty-session","request_id":"u-3","kind":"secret","prompt":"PTY secret input","default":"NEVER-PREFILL-ME"}`)
	return h
}
func (h *scriptedPTYHost) emit(raw string) {
	h.events<-harness.Event{Raw:json.RawMessage(raw)}
}
func (h *scriptedPTYHost) Events() <-chan harness.Event {return h.events}
func (h *scriptedPTYHost) Errors() <-chan error {return nil}
func (h *scriptedPTYHost) Close(context.Context) error {return nil}
func (h *scriptedPTYHost) Request(_ context.Context,command string,args any)(json.RawMessage,error) {
	if command!="ui_response" {return nil,fmt.Errorf("unexpected PTY harness command %q",command)}
	raw,err:=json.Marshal(args)
	if err!=nil{return nil,err}
	var reply ptyReply
	if err:=json.Unmarshal(raw,&reply);err!=nil{return nil,err}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.replies=append(h.replies,reply)
	switch reply.RequestID {
	case "u-1":
		h.emit(`{"type":"ui.dismiss","session_id":"pty-session","request_id":"u-1"}`)
	case "u-2":
		h.emit(`{"type":"ui.dismiss","session_id":"pty-session","request_id":"u-2"}`)
	case "u-3":
		h.emit(`{"type":"ui.dismiss","session_id":"pty-session","request_id":"u-3"}`)
		h.emit(`{"type":"ui.request","session_id":"pty-session","request_id":"u-4","kind":"confirm","prompt":"Cancel this approval?"}`)
		// A delayed completion of the old question must not close u-4.
		h.emit(`{"type":"ui.dismiss","session_id":"pty-session","request_id":"u-2"}`)
	case "u-4":
		h.emit(`{"type":"ui.dismiss","session_id":"pty-session","request_id":"u-4"}`)
		// Leave a real prompt visible during Ctrl+C teardown.
		h.emit(`{"type":"ui.request","session_id":"pty-session","request_id":"u-5","kind":"input","prompt":"Pending shutdown question"}`)
	default:
		return nil,fmt.Errorf("unexpected PTY reply to %q",reply.RequestID)
	}
	return json.RawMessage(`{"ok":true}`),nil
}

// The production model's Init boots Posoco; this wrapper supplies scripted
// EventHub messages instead. All Update/View and terminal behavior remain
// exactly the production Bubble Tea implementation.
type ptyBubbleTeaModel struct {model model; host *scriptedPTYHost}
func (m ptyBubbleTeaModel) Init() tea.Cmd{return receive(m.host.events)}
func (m ptyBubbleTeaModel) Update(msg tea.Msg)(tea.Model,tea.Cmd){
	next,cmd:=m.model.Update(msg)
	m.model=next.(model)
	return m,cmd
}
func (m ptyBubbleTeaModel) View() tea.View{return m.model.View()}

func TestInteractivePTYApprovals(t *testing.T) {
	if os.Getenv("CETAS_PTY_UI_HELPER")!="1" {t.Skip("PTY helper is run by tools/pty_ui_smoke.py")}
	trace:=os.Getenv("CETAS_PTY_UI_TRACE")
	if trace=="" {t.Fatal("missing PTY trace path")}
	h:=newScriptedPTYHost()
	m:=newModel()
	m.host=h
	m.feed=h.events
	m.session="pty-session"
	m.status="ready"
	_,err:=tea.NewProgram(ptyBubbleTeaModel{model:m,host:h}).Run()
	if err!=nil {t.Fatalf("Bubble Tea PTY program failed: %v",err)}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.replies)!=4 {t.Fatalf("expected 4 UI responses before Ctrl+C, got %d: %#v",len(h.replies),h.replies)}
	want:=[]string{"u-1","u-2","u-3","u-4"}
	for i,reply:=range h.replies {
		if reply.RequestID!=want[i] {t.Fatalf("out-of-order request %d: got %q want %q",i,reply.RequestID,want[i])}
	}
	if h.replies[0].Selected==nil||*h.replies[0].Selected!=2 {t.Fatalf("approval selection: %#v",h.replies[0])}
	if h.replies[1].Text==nil||*h.replies[1].Text!="你好 Cetas" {t.Fatalf("CJK input was corrupted: %#v",h.replies[1])}
	if !h.replies[2].Cancelled||h.replies[2].Text!=nil {t.Fatalf("secret Esc must cancel without disclosure: %#v",h.replies[2])}
	if !h.replies[3].Cancelled {t.Fatalf("approval Esc must cancel: %#v",h.replies[3])}
	data,err:=json.MarshalIndent(h.replies,"","  ")
	if err!=nil {t.Fatal(err)}
	if err:=os.WriteFile(trace,data,0600);err!=nil {t.Fatal(err)}
}
