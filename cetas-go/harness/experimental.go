package harness

import (
 "context"
 "encoding/json"
 "fmt"
)

// Experimental features are a separate native capability surface. Managing
// Pi packages never installs or enables a JavaScript runtime.
type experimentalReply struct {
 Installed bool `json:"installed"`
 Enabled bool `json:"enabled"`
 Version string `json:"version"`
 Lines []string `json:"lines,omitempty"`
}
func(s *piSupervisor) experimentalCommand(ctx context.Context,args any)(json.RawMessage,error){
 var req struct{Action string `json:"action"`}
 raw,err:=json.Marshal(args)
 if err!=nil{return nil,err}
 if err=json.Unmarshal(raw,&req);err!=nil{return nil,err}
 s.mu.Lock()
 home:=s.home
 s.mu.Unlock()
 home,err=piHome(home)
 if err!=nil{return nil,err}
 response:=experimentalReply{Version:experimentalBunVersion}
 switch req.Action {
 case "","status":
 case "prepare":
  path,err:=prepareBun(ctx,home)
  if err!=nil{return nil,fmt.Errorf("install Bun Runtime: %w",err)}
  if err=verifyBunBinary(ctx,path);err!=nil{return nil,err}
  response.Lines=[]string{"Bun Runtime "+experimentalBunVersion+" installed.","Open /experimental again to enable it."}
 case "enable":
  path,installed,e:=bunPrepared(home)
  if e!=nil{return nil,e}
  if !installed{return nil,fmt.Errorf("Bun Runtime not installed; choose Install in /experimental first")}
  if err=verifyBunBinary(ctx,path);err!=nil{return nil,err}
  if err=setBunGuestEnabled(home,true);err!=nil{return nil,err}
  response.Lines=[]string{"Bun Runtime enabled for new sessions.","Restart Cetas to replace an existing Pi guest."}
 case "disable":
  if err=setBunGuestEnabled(home,false);err!=nil{return nil,err}
  response.Lines=[]string{"Bun Runtime disabled for new sessions.","Restart Cetas to replace an existing Pi guest."}
 default:
  return nil,fmt.Errorf("unknown experimental action %q",req.Action)
 }
 _,response.Installed,err=bunPrepared(home)
 if err!=nil{return nil,err}
 response.Enabled,err=bunGuestEnabled(home)
 if err!=nil{return nil,err}
 return json.Marshal(response)
}
