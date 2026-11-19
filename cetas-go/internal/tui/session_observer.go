package tui

import (
	"context"
	"encoding/json"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/colmugx/cetas/cetas-go/internal/wire"
)

// remoteSessionOwner is optional: existing mock/local Runtimes keep the
// normal standalone Session picker behavior.
type remoteSessionOwner interface {
	RemoteOwnerExpected() bool
	ObserveSession(context.Context, string) (*wire.SessionObservation, error)
}

type remoteAttachResult struct {
	sessionID string
	observation *wire.SessionObservation
	err error
}

// The user chose a Session held by a DIFFERENT process. Never call the
// local switch_session RPC: it could independently open the writer journal.
func (m *model) observeRemoteIfContended(sessionID string) (tea.Cmd, bool) {
	owner, ok := m.host.(remoteSessionOwner)
	if !ok || (!owner.RemoteOwnerExpected() && !m.remoteReadOnly) {
		return nil, false
	}
	if sessionID == m.session && m.remoteReadOnly {
		m.closeSessionPicker()
		return nil, true
	}
	m.switchInFlight = sessionID
	return func() tea.Msg {
		ctx,cancel:=context.WithTimeout(context.Background(),8*time.Second)
		defer cancel()
		view,err:=owner.ObserveSession(ctx,sessionID)
		return remoteAttachResult{sessionID:sessionID,observation:view,err:err}
	}, true
}

func receiveRemoteObservation(view *wire.SessionObservation,generation uint64) tea.Cmd {
	if view==nil{return nil}
	return func()tea.Msg {
		first,ok:=<-view.Events
		if !ok{return eventBatchResult{closed:true,remote:true,remoteGeneration:generation}}
		events:=[]wire.Event{first}
		for len(events)<64 {
			select{
			case next,ok:=<-view.Events:
				if !ok{return eventBatchResult{events:events,closed:true,remote:true,remoteGeneration:generation}}
				events=append(events,next)
			default:
				return eventBatchResult{events:events,remote:true,remoteGeneration:generation}
			}
		}
		return eventBatchResult{events:events,remote:true,remoteGeneration:generation}
	}
}

func (m *model) installRemoteObservation(msg remoteAttachResult) tea.Cmd {
	if msg.sessionID=="" || m.switchInFlight!=msg.sessionID {
		if msg.observation!=nil { _=msg.observation.Close() }
		return nil
	}
	m.switchInFlight=""
	if msg.err!=nil || msg.observation==nil {
		m.err="remote Session attach: "+formatRemoteAttachError(msg.err)
		// A failed observation cannot fall back to composing a second
		// writer for an actively owned Session.
		return nil
	}
	if m.remoteObservation!=nil {_=m.remoteObservation.Close()}
	m.remoteGeneration++
	m.remoteObservation=msg.observation
	m.remoteReadOnly=true
	m.closeSessionPicker()
	m.pendingSessionCmd=m.retireSessionPresentation()
	m.eventCursor=0
	m.runtimeEpoch=""
	m.eventResyncPending=false
	m.eventResyncAwaitingSnapshot=false
	m.session=msg.sessionID
	m.welcomeHidden=true
	m.dynamicCommands=nil
	m.commandSession=""
	m.clearTranscriptSearch()
	m.resetVirtualTranscript()
	m.transcript=nil
	m.markdownRaw=nil
	m.markdownCache.reset()
	m.toolIndex=nil
	m.streaming=""
	m.reasoning=""
	m.running=false
	m.followups=nil
	m.snapshotSurface(msg.observation.Snapshot)
	m.applyEvent(wire.Event{Type:"session.snapshot",Raw:json.RawMessage(msg.observation.Snapshot)})
	if m.running {m.status="working · remote Session (read-only)"} else {m.status="remote Session (read-only)"}
	return tea.Batch(m.pendingSessionCmd,receiveRemoteObservation(m.remoteObservation,m.remoteGeneration))
}

func formatRemoteAttachError(err error)string{
	if err==nil{return "owner unavailable"}
	return err.Error()+" (no second Session writer was started)"
}
