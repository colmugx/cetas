package tui

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/colmugx/cetas/cetas-go/internal/tui/overlays"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
)

type remoteOwnerTestHost struct {
	testHost
	observe func(context.Context,string)(*wire.SessionObservation,error)
}

func (*remoteOwnerTestHost) RemoteOwnerExpected() bool { return true }
func (h *remoteOwnerTestHost) ObserveSession(ctx context.Context,id string)(*wire.SessionObservation,error){
	return h.observe(ctx,id)
}

func TestPickerObservesOtherOwnerAndRendersWorkingOutput(t *testing.T){
	frames:=make(chan wire.Event,4)
	var closed bool
	h:=&remoteOwnerTestHost{observe:func(_ context.Context,id string)(*wire.SessionObservation,error){
		if id!="foreign"{t.Fatalf("wrong owner Session requested: %s",id)}
		return &wire.SessionObservation{
			Snapshot:json.RawMessage(`{"type":"session.snapshot","session_id":"foreign","runtime_epoch":"e-1","cursor":5,"high_water_cursor":5,"busy":true}`),
			Events:frames,
			Close:func()error{closed=true;return nil},
		},nil
	}}
	m:=switchPickerModel(t,h)
	entry:=overlays.SessionEntry{ID:"foreign",Current:true}
	cmd:=m.sessionPickerChoose(entry)
	if cmd==nil{t.Fatal("did not start owner attach")}
	result,ok:=cmd().(remoteAttachResult)
	if !ok{t.Fatalf("unexpected picker command: %#v",cmd())}
	m.installRemoteObservation(result)
	if !m.remoteReadOnly||!m.running||m.session!="foreign"{
		t.Fatalf("owner snapshot not installed: session=%q running=%v readonly=%v",m.session,m.running,m.remoteReadOnly)
	}
	m.textarea.SetValue("do not execute")
	if cmd:=m.submitEditor();cmd!=nil{t.Fatal("read-only observer dispatched an Agent request")}
	if !strings.Contains(m.err,"read-only"){t.Fatalf("missing read-only feedback: %q",m.err)}
	// A foreign local-runtime event cannot overwrite the owner stream.
	next,_:=m.update(eventBatchResult{events:[]wire.Event{event(`{"type":"turn.completed","session_id":"foreign","runtime_epoch":"e-1"}`)}})
	m=next.(model)
	if !m.running{t.Fatal("standalone event cleared owner working")}
	next,_=m.update(eventBatchResult{events:[]wire.Event{
		event(`{"type":"assistant.text_delta","session_id":"foreign","runtime_epoch":"e-1","cursor":6,"cursor_advance":true,"delta":"live"}`),
		event(`{"type":"turn.completed","session_id":"foreign","runtime_epoch":"e-1","cursor":7,"cursor_advance":true}`),
	},remote:true,remoteGeneration:m.remoteGeneration})
	m=next.(model)
	if m.running||len(m.transcript)==0||m.transcript[len(m.transcript)-1]!="live"{
		t.Fatalf("live turn not displayed: running=%v transcript=%q",m.running,m.transcript)
	}
	_ = m.remoteObservation.Close()
	if !closed{t.Fatal("owner observation not closed")}
}

func TestPickerRefusesCompetingOwnerSessionWhenTransportUnavailable(t *testing.T){
	h:=&remoteOwnerTestHost{observe:func(context.Context,string)(*wire.SessionObservation,error){
		return nil,errors.New("named pipe unavailable")
	}}
	m:=switchPickerModel(t,h)
	cmd:=m.sessionPickerChoose(overlays.SessionEntry{ID:"foreign",Current:true})
	if cmd==nil{t.Fatal("missing safe owner attach")}
	result:=cmd().(remoteAttachResult)
	m.installRemoteObservation(result)
	if m.session!="s-current"||m.remoteReadOnly{
		t.Fatalf("failed observer changed Session: %q readonly=%v",m.session,m.remoteReadOnly)
	}
	if !strings.Contains(m.err,"no second Session writer"){t.Fatalf("missing safety warning: %q",m.err)}
}

func TestRemoteStreamClosureKeepsSessionReadOnly(t *testing.T){
	m:=switchPickerModel(t,&testHost{})
	m.remoteReadOnly=true
	m.remoteObservation=&wire.SessionObservation{Events:make(chan wire.Event),Close:func()error{return nil}}
	m.remoteGeneration=7
	result,_:=m.update(eventBatchResult{closed:true,remote:true,remoteGeneration:7})
	m=result.(model)
	if !m.remoteReadOnly||m.remoteObservation!=nil||!strings.Contains(m.status,"disconnected"){
		t.Fatalf("closed observer silently became a writer: readonly=%v status=%s",m.remoteReadOnly,m.status)
	}
}
