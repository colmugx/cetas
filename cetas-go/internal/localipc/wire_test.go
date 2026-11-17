package localipc

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
)

func TestCodecRoundTrip(t *testing.T) {
	var raw bytes.Buffer
	out := NewCodec(strings.NewReader(""), &raw)
	msg := Envelope{Type: "request", SurfaceID: "surface-1", RequestID: "req-1", Command: "session.attach", Args: json.RawMessage(`{"cwd":"/tmp","session_id":"s-1"}`)}
	if err := out.Write(msg); err != nil { t.Fatal(err) }
	got, err := NewCodec(&raw, io.Discard).Read()
	if err != nil { t.Fatal(err) }
	if got.Type != msg.Type || got.RequestID != msg.RequestID ||
		string(got.Args) != string(msg.Args) { t.Fatalf("mismatched envelope: %+v", got) }
}

func TestCodecBoundsAndMalformed(t *testing.T) {
	for _, tc := range []struct{name string; wire string; want error}{
		{"unknown", `{"type":"unrecognized"}`+"\n", ErrProtocol},
		{"primitive", `"hello"`+"\n", ErrProtocol},
		{"unterminated", `{"type":"hello"}`, ErrProtocol},
		{"oversized", strings.Repeat("x", MaxFrameSize+1)+"\n", ErrFrameTooLarge},
	} {
		t.Run(tc.name, func(t *testing.T){
			_, err := NewCodec(strings.NewReader(tc.wire), io.Discard).Read()
			if !errors.Is(err, tc.want){ t.Fatalf("got %v want %v", err, tc.want) }
		})
	}
	var b bytes.Buffer
	if err:=NewCodec(strings.NewReader(""), &b).Write(Envelope{Type:"event",Event:json.RawMessage(`{"data":"ok"}`)});err!=nil{t.Fatal(err)}
	if err:=NewCodec(strings.NewReader(""), &b).Write(Envelope{Type:"event",Event:json.RawMessage(`{"invalid"`)});err==nil{t.Fatal("accepted invalid raw event")}
}

func TestHandshakeAndCapabilityNegotiation(t *testing.T) {
	s, c := net.Pipe()
	defer s.Close()
	defer c.Close()
	hello := Envelope{Type:"hello",Protocol:Protocol,Host:"cetas-go",ClientInstanceID:"client-1",
		Capabilities:[]string{"surface.attach","event.cursor.v1","unsupported"},Required:[]string{"surface.attach"}}
	type result struct{got Envelope;err error}
	done:=make(chan result,1)
	go func(){
		got,err:=ServerHandshake(NewCodec(s,s),OwnerInfo{InstanceID:"owner-1",RuntimeEpoch:"epoch-1",Capabilities:[]string{"surface.attach","event.cursor.v1"}})
		done<-result{got,err}
	}()
	reply,err:=ClientHandshake(NewCodec(c,c),hello)
	if err!=nil{t.Fatal(err)}
	if reply.OwnerInstanceID!="owner-1" || reply.RuntimeEpoch!="epoch-1" || len(reply.Capabilities)!=2 ||
		reply.MaxFrameSize!=MaxFrameSize {t.Fatalf("bad welcome: %+v",reply)}
	if served:=<-done;served.err!=nil || served.got.ClientInstanceID!="client-1"{t.Fatalf("bad server handshake: %+v",served)}
}

func TestHandshakeRejectsMissingCapability(t *testing.T){
	s,c:=net.Pipe()
	defer s.Close()
	defer c.Close()
	go func(){ _,_=ServerHandshake(NewCodec(s,s),OwnerInfo{InstanceID:"owner",RuntimeEpoch:"e",Capabilities:[]string{"event.cursor.v1"}}) }()
	_,err:=ClientHandshake(NewCodec(c,c),Envelope{Type:"hello",Protocol:Protocol,Host:"go",ClientInstanceID:"client",Capabilities:[]string{"surface.attach"},Required:[]string{"surface.attach"}})
	if !errors.Is(err,ErrProtocol){t.Fatalf("expected refusal, got %v",err)}
}

func TestCodecConcurrentWritesDoNotInterleave(t *testing.T){
	var mu sync.Mutex
	var wire bytes.Buffer
	// A deliberately short writer forces each envelope through many writes.
	writer:=shortWriter{write:func(p []byte)(int,error){
		mu.Lock();defer mu.Unlock()
		n:=min(7,len(p));return wire.Write(p[:n])
	}}
	c:=NewCodec(strings.NewReader(""),writer)
	var wg sync.WaitGroup
	for i:=0;i<16;i++{
		wg.Add(1)
		go func(){defer wg.Done();if err:=c.Write(Envelope{Type:"ping"});err!=nil{t.Error(err)}}()
	}
	wg.Wait()
	r:=NewCodec(&wire,io.Discard)
	for i:=0;i<16;i++{frame,err:=r.Read();if err!=nil||frame.Type!="ping"{t.Fatalf("frame %d: %+v %v",i,frame,err)}}
}
type shortWriter struct{write func([]byte)(int,error)}
func (s shortWriter) Write(p []byte)(int,error){return s.write(p)}
