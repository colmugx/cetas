package harness

import (
 "encoding/json"
 "strings"
 "testing"
)

func TestNativeHostActivityFramesAndClose(t *testing.T){
 h:=newHost(nil)
 h.activity("pi:test","Pi install · test","running","Resolving",0,0)
 evt:=<-h.Events()
 if evt.Type!="host.activity"{t.Fatalf("unexpected type: %s",evt.Type)}
 var frame struct{
  Type string `json:"type"`
  ID string `json:"id"`
  Label string `json:"label"`
  State string `json:"state"`
 }
 if err:=json.Unmarshal(evt.Raw,&frame);err!=nil{t.Fatal(err)}
 if frame.Type!="host.activity"||frame.ID!="pi:test"||frame.State!="running"{
  t.Fatalf("bad host activity: %+v",frame)
 }
 h.activity("pi:test","Pi install · test","succeeded","Installed",0,0)
 select{case final:=<-h.Events():
  if !strings.Contains(string(final.Raw),`"state":"succeeded"`){t.Fatalf("missing success: %s",final.Raw)}
 default:t.Fatal("success event not delivered")}
 h.closeActivityEvents()
 h.activity("pi:test","Pi install · test","failed","late event",0,0)
}
