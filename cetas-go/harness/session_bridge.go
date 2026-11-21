package harness

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "net"
    "sync"

    sb "github.com/colmugx/posoco-extension/posoco-ext-session-bridge/go"
)

// sessionStream is one bounded, Session-filtered view of the existing
// ConsoleRuntime EventHub. It is NOT another Agent or writable SessionStore.
type sessionStream struct {
    sessionID string
    frames chan json.RawMessage
}

// observerServer transports read-only Session snapshots/frames to a local
// same-user socket/pipe. Localipc owns OS endpoint security and the kernel
// lease; the portable posoco-ext bridge owns framing and negotiation.
type observerServer struct {
    listener net.Listener
    owner sb.Owner
    host *Host
    ctx context.Context
    cancel context.CancelFunc
    slots chan struct{}
    stopped chan struct{}
    peersMu sync.Mutex
    peers map[net.Conn]struct{}
    wg sync.WaitGroup
    once sync.Once
}

func startObserverServer(listener net.Listener,owner sb.Owner,host *Host)*observerServer{
    ctx,cancel:=context.WithCancel(context.Background())
    s:=&observerServer{listener:listener,owner:owner,host:host,ctx:ctx,
        cancel:cancel,slots:make(chan struct{},16),stopped:make(chan struct{}),
        peers:make(map[net.Conn]struct{})}
    go s.accept()
    return s
}

func (s *observerServer) accept(){
    defer close(s.stopped)
    for {
        conn,err:=s.listener.Accept()
        if err!=nil{return}
        select{
        case <-s.ctx.Done():_ = conn.Close();return
        case s.slots<-struct{}{}:
        default:_ = conn.Close();continue
        }
        s.peersMu.Lock()
        if s.ctx.Err()!=nil{
            s.peersMu.Unlock()
            <-s.slots
            _ = conn.Close()
            return
        }
        s.peers[conn]=struct{}{}
        s.wg.Add(1)
        s.peersMu.Unlock()
        go func(){
            defer s.wg.Done()
            defer func(){
                s.peersMu.Lock()
                delete(s.peers,conn)
                s.peersMu.Unlock()
                <-s.slots
                _ = conn.Close()
            }()
            _ = sb.ServeConn(s.ctx,conn,s.owner,s.host.subscribeSession)
        }()
    }
}

func (s *observerServer) Close()error{
    if s==nil{return nil}
    var err error
    s.once.Do(func(){
        s.cancel()
        err=s.listener.Close()
        s.peersMu.Lock()
        for peer:=range s.peers{_ = peer.Close()}
        s.peersMu.Unlock()
        <-s.stopped
        s.wg.Wait()
    })
    return err
}

// subscribeSession subscribes BEFORE reading the snapshot, so a turn event
// racing initial attachment cannot disappear between snapshot and live tail.
// Unknown/uncomposed sessions are rejected without composing a new Agent.
func (h *Host) subscribeSession(ctx context.Context,sessionID string)(sb.Subscription,error){
    if sessionID=="" {return sb.Subscription{},errors.New("empty Session ID")}
    id:=h.nextStreamID.Add(1)
    stream:=sessionStream{sessionID:sessionID,frames:make(chan json.RawMessage,128)}
    h.streamsMu.Lock()
    if h.streamsClosed{
        h.streamsMu.Unlock()
        return sb.Subscription{},ErrClosed
    }
    h.streams[id]=stream
    h.streamsMu.Unlock()
    var once sync.Once
    release:=func(){
        once.Do(func(){
            h.streamsMu.Lock()
            if current,exists:=h.streams[id];exists{
                delete(h.streams,id)
                close(current.frames)
            }
            h.streamsMu.Unlock()
        })
    }
    snapshot,err:=h.requestNative(ctx,"session_observe",map[string]string{"session_id":sessionID})
    if err!=nil {
        release()
        // The runtime's refusal carries a machine-readable code when the
        // Session was never composed here: surface it as the typed bridge
        // error so the reject frame tells viewers a local writable fallback
        // is safe instead of failing closed on a protocol ambiguity.
        var refusal struct{
            Code string `json:"code"`
        }
        if json.Unmarshal(snapshot,&refusal)==nil&&refusal.Code==sb.ErrCodeSessionNotComposed{
            return sb.Subscription{},fmt.Errorf("%w: %w",sb.ErrSessionNotComposed,err)
        }
        return sb.Subscription{},err
    }
    var summary struct{
        Type string `json:"type"`
        SessionID string `json:"session_id"`
    }
    if json.Unmarshal(snapshot,&summary)!=nil||
        summary.Type!="session.snapshot"||summary.SessionID!=sessionID{
        release()
        return sb.Subscription{},errors.New("Session not owned by this Runtime")
    }
    return sb.Subscription{Snapshot:snapshot,Events:stream.frames,Close:release},nil
}

func (h *Host) publishSessionFrame(payload []byte){
    var id struct{SessionID string `json:"session_id"`}
    if json.Unmarshal(payload,&id)!=nil||id.SessionID==""{return}
    h.streamsMu.Lock()
    defer h.streamsMu.Unlock()
    if h.streamsClosed{return}
    for key,stream:=range h.streams{
        if stream.sessionID!=id.SessionID{continue}
        copy:=append(json.RawMessage(nil),payload...)
        select {
        case stream.frames<-copy:
        default:
            // Slow viewer must resnapshot. Never drop an event and continue
            // with a false cursor, nor stall the owner or local TUI.
            delete(h.streams,key)
            close(stream.frames)
        }
    }
}

func (h *Host) closeSessionStreams(){
    h.streamsMu.Lock()
    defer h.streamsMu.Unlock()
    h.streamsClosed=true
    for key,stream:=range h.streams{
        close(stream.frames)
        delete(h.streams,key)
    }
}
