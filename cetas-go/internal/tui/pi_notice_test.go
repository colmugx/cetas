package tui

import (
 "strings"
 "testing"
)

type unavailablePiHost struct{ testHost }
func (*unavailablePiHost) PiAvailable() bool {return false}
type availablePiHost struct{ testHost }
func (*availablePiHost) PiAvailable() bool {return true}

func TestNativePiNoticeAtStartupOnlyWhenUnavailable(t *testing.T) {
 m:=newModel()
 state,_:=m.Update(bootResult{host:&unavailablePiHost{},needsSetup:true})
 result:=state.(model)
 if len(result.transcript)!=1||!strings.Contains(result.transcript[0],"/experimental"){
  t.Fatalf("missing native-only startup notice: %v",result.transcript)
 }
 if block,ok:=result.blocks[0];!ok||block.Kind!="notice" {
  t.Fatalf("startup hint should be muted notice: %#v",result.blocks)
 }
 m=newModel()
 state,_=m.Update(bootResult{host:&availablePiHost{},needsSetup:true})
 if len(state.(model).transcript)!=0{t.Fatal("notice shown with Bun ready")}
}

func TestPiCommandNotifiesWithoutBun(t *testing.T) {
 m:=newModel()
 m.host=&unavailablePiHost{}
 cmd:=m.command("/pi list")
 if cmd==nil {t.Fatal("/pi not dispatched")}
 if len(m.transcript)!=1||!strings.Contains(m.transcript[0],"/experimental"){
  t.Fatalf("missing /pi hint: %#v",m.transcript)
 }
 if m.blocks[0].Kind!="notice" {t.Fatal("/pi hint is not muted")}
 m.host=&availablePiHost{}
 count:=len(m.transcript)
 if cmd=m.command("/pi list");cmd==nil||len(m.transcript)!=count{
  t.Fatal("/pi emitted unavailable notice for ready Bun")
 }
}
