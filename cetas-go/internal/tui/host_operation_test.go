package tui

import (
 "encoding/json"
 "strings"
 "testing"
 "time"

 "github.com/colmugx/cetas/cetas-go/internal/wire"
)

func TestNativeHostProgressUsesActivitiesArea(t *testing.T) {
 m:=newModel()
 progress:=map[string]any{
  "type":"host.activity","id":"bun:download",
  "label":"Bun Runtime","state":"running","detail":"Downloading",
  "current":5<<20,"total":10<<20,
 }
 raw,err:=json.Marshal(progress)
 if err!=nil{t.Fatal(err)}
 m.applyEvent(wire.Event{Type:"host.activity",Raw:raw})
 view:=strings.Join(m.activityLines(100,8),"\n")
 if !strings.Contains(view,"Bun Runtime")||!strings.Contains(view,"50%"){
  t.Fatalf("download not visible in activities: %q",view)
 }
 if len(m.transcript)!=0 {t.Fatal("activity leaked into Agent transcript")}
 progress["state"]="succeeded"
 progress["detail"]="Verified"
 raw,err=json.Marshal(progress)
 if err!=nil{t.Fatal(err)}
 m.applyEvent(wire.Event{Type:"host.activity",Raw:raw})
 if text:=strings.Join(m.activityLines(100,8),"\n");!strings.Contains(text,"Verified"){t.Fatalf("terminal activity absent: %q",text)}
 op:=m.surface.activities.host["bun:download"]
 if op==nil{t.Fatal("host activity not retained")}
 m.surface.activities.expire(op.Settled.Add(16*time.Second))
 if len(m.activityLines(100,8))!=0 {t.Fatal("expired activity still visible")}
}
