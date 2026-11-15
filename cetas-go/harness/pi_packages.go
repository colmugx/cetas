package harness

// Pi package management belongs to the Go host: npm never executes on the
// MoonBit scheduler thread, and the allowlist remains deny-by-default.
import (
 "context"
 "encoding/json"
 "fmt"
 "os"
 "os/exec"
 "path/filepath"
 "sort"
 "strings"
 "regexp"
 "sync"
)

var piPackageName = regexp.MustCompile(`^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$`)
var piInstallMu sync.Mutex

type piSnapshot struct {
 Raw map[string]json.RawMessage
 Packages []string
 Manager string
}

func piHome(value string)(string,error){
 if value!="" {return value,nil}
 if home:=os.Getenv("CETAS_HOME");home!="" {return home,nil}
 return os.UserHomeDir()
}
func readPiSnapshot(path string)(piSnapshot,error){
 cfg:=piSnapshot{Raw:map[string]json.RawMessage{},Manager:"npm"}
 raw,err:=os.ReadFile(path)
 if os.IsNotExist(err) {return cfg,nil}
 if err!=nil {return cfg,err}
 if err=json.Unmarshal(raw,&cfg.Raw);err!=nil{return cfg,fmt.Errorf("invalid pi-packages.json: %w",err)}
 if v,ok:=cfg.Raw["packages"];ok {
  if err=json.Unmarshal(v,&cfg.Packages);err!=nil{return cfg,fmt.Errorf("invalid Pi packages list: %w",err)}
 }
 if v,ok:=cfg.Raw["npmCommand"];ok {
  var manager string
  if json.Unmarshal(v,&manager)==nil&&strings.TrimSpace(manager)!="" {cfg.Manager=strings.TrimSpace(manager)}
  if manager=="" {
   var choices []string
   if json.Unmarshal(v,&choices)==nil {
    for _,item:=range choices {if strings.TrimSpace(item)!="" {cfg.Manager=strings.TrimSpace(item);break}}
   }
  }
 }
 return cfg,nil
}
func piPackageDependencies(root string)map[string]bool{
 deps:=map[string]bool{}
 data,err:=os.ReadFile(filepath.Join(root,"package.json"))
 if err!=nil {return deps}
 var p struct {Dependencies map[string]any `json:"dependencies"`}
 if json.Unmarshal(data,&p)==nil {for k:=range p.Dependencies {deps[k]=true}}
 return deps
}
func writePiSnapshot(path string,config piSnapshot)error{
 next,err:=json.MarshalIndent(config.Packages,"","  ")
 if err!=nil{return err}
 config.Raw["packages"]=next
 content,err:=json.MarshalIndent(config.Raw,"","  ")
 if err!=nil{return err}
 return os.WriteFile(path,append(content,'\n'),0600)
}
func piLines(lines ...string)(json.RawMessage,error){
 payload,err:=json.Marshal(map[string]any{"lines":lines})
 return payload,err
}
func (s *piSupervisor) packageCommand(ctx context.Context,args any)(json.RawMessage,error){
 var req struct{Args string `json:"args"`}
 data,err:=json.Marshal(args)
 if err!=nil{return nil,err}
 if err=json.Unmarshal(data,&req);err!=nil{return nil,err}
 words:=strings.Fields(req.Args)
 cmd:="list"
 if len(words)>0 {cmd=words[0]}
 if cmd=="help" {return piLines("usage: /pi install <package>","       /pi remove <package>","       /pi list","       /pi runtime status|prepare|enable|disable","Experimental Bun is downloaded only by /pi runtime prepare; activation requires /pi runtime enable and an app restart.","Packages are allowlisted via ~/.cetas/pi-packages.json; changes require a restart.")}
 s.mu.Lock()
 home:=s.home
 s.mu.Unlock()
 home,err=piHome(home)
 if err!=nil{return nil,err}
 if cmd=="runtime" {
  if len(words)>2 {return piLines("usage: /pi runtime status|prepare")}
  action:="status"
  if len(words)==2 {action=words[1]}
  if action!="status"&&action!="prepare"&&action!="enable"&&action!="disable" {return piLines("usage: /pi runtime status|prepare|enable|disable")}
  path,ready,err:=bunPrepared(home)
  if err!=nil {return nil,err}
  enabled,err:=bunGuestEnabled(home)
  if err!=nil{return nil,err}
  if action=="status" {
   state:="disabled (moejs guest)"
   if enabled {state="enabled (Bun guest on next session/restart)"}
   if ready {return piLines("Bun "+experimentalBunVersion+" is cached at "+path,"Experimental Pi runtime: "+state)}
   return piLines("Bun "+experimentalBunVersion+" is not downloaded","Experimental Pi runtime: "+state,"Run /pi runtime prepare to download and verify the official archive.")
  }
  if action=="prepare" {
   path,err=prepareBun(ctx,home)
   if err!=nil {return nil,err}
   if err=verifyBunBinary(ctx,path);err!=nil{return nil,err}
   return piLines("Bun "+experimentalBunVersion+" prepared at "+path,"Run /pi runtime enable to select the Bun guest for new sessions.")
  }
  if action=="disable" {
   if err=setBunGuestEnabled(home,false);err!=nil{return nil,err}
   return piLines("Experimental Bun guest disabled.","Restart cetas-go to retire the current guest.")
  }
  if !ready {return piLines("Bun is not prepared; run /pi runtime prepare first.")}
  if err=verifyBunBinary(ctx,path);err!=nil{return nil,err}
  if err=setBunGuestEnabled(home,true);err!=nil{return nil,err}
  return piLines("Experimental Bun Pi guest enabled.","Restart cetas-go (or create a new session) to activate it.")
 }
 root:=filepath.Join(home,".cetas","pi-packages")
 configPath:=filepath.Join(home,".cetas","pi-packages.json")
 piInstallMu.Lock()
 defer piInstallMu.Unlock()
 snapshot,err:=readPiSnapshot(configPath)
 if err!=nil{return nil,err}
 if cmd=="list" {
  if len(snapshot.Packages)==0 {return piLines("no Pi packages configured","Install using /pi install <package>.")}
  lines:=[]string{"Pi packages (allowlist):"}
  for _,pkg:=range snapshot.Packages {
   candidates:=[]string{filepath.Join(root,"node_modules",pkg,"package.json"),filepath.Join(root,pkg,"package.json")}
   status:="missing"
   for _,manifest:=range candidates {if _,err:=os.Stat(manifest);err==nil {status="installed";break}}
   lines=append(lines,fmt.Sprintf("%s  %s",status,pkg))
  }
  return piLines(lines...)
 }
 if cmd!="install"&&cmd!="remove" {return piLines("unknown /pi subcommand: "+cmd,"Use /pi help")}
 if len(words)!=2||!piPackageName.MatchString(words[1])||strings.HasPrefix(words[1],"-") {
  return piLines("invalid package name; usage: /pi "+cmd+" <package>")
 }
 pkg:=words[1]
 if cmd=="remove" {
  present:=false
  for _,name:=range snapshot.Packages {if name==pkg {present=true;break}}
  if !present{return piLines(pkg+" is not in the Pi allowlist")}
  if _,err:=os.Stat(root);err!=nil{return piLines("Pi package root not found: "+root)}
 }else{
  if err=os.MkdirAll(root,0700);err!=nil{return nil,err}
  manifest:=filepath.Join(root,"package.json")
  if _,err:=os.Stat(manifest);os.IsNotExist(err){
   if err=os.WriteFile(manifest,[]byte(`{"name":"cetas-pi-packages","private":true,"type":"module"}`+"\n"),0600);err!=nil{return nil,err}
  }
 }
 before:=piPackageDependencies(root)
 // Executed with argv, never a shell; package spec is a single validated arg.
 runner:=exec.CommandContext(ctx,snapshot.Manager,map[bool]string{true:"add",false:"remove"}[cmd=="install"],pkg)
 runner.Dir=root
 runner.Stdin=nil
 output,err:=runner.CombinedOutput()
 if err!=nil {
  msg:=strings.TrimSpace(string(output))
  if len(msg)>1200 {msg=msg[len(msg)-1200:]}
  return piLines(fmt.Sprintf("/pi %s %s failed: %v",cmd,pkg,err),msg)
 }
 if cmd=="install" {
  name:=pkg
  added:=[]string{}
  for dep:=range piPackageDependencies(root){if !before[dep]{added=append(added,dep)}}
  sort.Strings(added)
  if len(added)==1{name=added[0]}
  found:=false
  for _,configured:=range snapshot.Packages {if configured==name {found=true;break}}
  if !found {snapshot.Packages=append(snapshot.Packages,name)}
  if err=writePiSnapshot(configPath,snapshot);err!=nil{return nil,err}
  return piLines("/pi install "+pkg+": added "+name+" to allowlist","Restart cetas-go to activate the installed extension.")
 }
 kept:=make([]string,0,len(snapshot.Packages))
 for _,name:=range snapshot.Packages {if name!=pkg{kept=append(kept,name)}}
 snapshot.Packages=kept
 if err=writePiSnapshot(configPath,snapshot);err!=nil{return nil,err}
 return piLines("/pi remove "+pkg+": removed from allowlist","Restart cetas-go to release any already-loaded tools.")
}
