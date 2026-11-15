package nativepi

import (
 "bufio"
 _ "embed"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "os"
 "os/exec"
 "path/filepath"
 "sync"
 "time"
)

//go:embed bun_guest.mjs
var bunWorkerScript []byte

// RuntimeGuest is the shared kernel-facing contract for an in-process
// lightweight guest and an opt-in, isolated Bun subprocess.
type RuntimeGuest interface {
 Catalog() ([]Tool,uint64)
 Emit([]byte) error
 Execute(string,string,json.RawMessage) Result
 Diagnostics() []string
 Close()
}

type bunReply struct {
 ID uint64 `json:"id"`
 Kind string `json:"kind"`
 Tools []Tool `json:"tools"`
 Generation uint64 `json:"generation"`
 Warnings []string `json:"warnings"`
 Result Result `json:"result"`
 Error string `json:"error"`
}
type BunGuest struct {
 mu sync.Mutex
 cmd *exec.Cmd
 input io.WriteCloser
 output *bufio.Scanner
 done chan error
 script string
 cwd string
 next uint64
 catalog []Tool
 generation uint64
 warnings []string
 events EventBridge
 closeOnce sync.Once
}

// The Bun subprocess must not inherit provider tokens, SDK keys or Cetas
// authentication variables from the native host's environment. These
// platform runtime variables enable core Node/Bun functionality only.
// Further extension capabilities require an explicit permission design.
func bunGuestEnv(home string) []string {
 keys:=[]string{"PATH","SYSTEMROOT","WINDIR","HOME","USERPROFILE",
  "HOMEDRIVE","HOMEPATH","TMPDIR","TMP","TEMP","LANG","LC_ALL","TERM"}
 env:=make([]string,0,len(keys)+1)
 for _,key:=range keys {
  if value,ok:=os.LookupEnv(key);ok {env=append(env,key+"="+value)}
 }
 return append(env,"CETAS_HOME="+home)
}

// OpenBun never downloads a runtime. The caller must explicitly prepare
// a checked binary and opt into using it before starting this subprocess.
func OpenBun(binary, home, cwd string) (*BunGuest,error) {
 if !filepath.IsAbs(binary) {return nil,errors.New("Bun binary path must be absolute")}
 if stat,err:=os.Stat(binary);err!=nil||!stat.Mode().IsRegular() {return nil,fmt.Errorf("Bun binary unavailable at %s: %v",binary,err)}
 file,err:=os.CreateTemp("","cetas-pi-bun-*.mjs")
 if err!=nil{return nil,err}
 script:=file.Name()
 if _,err=file.Write(bunWorkerScript);err!=nil {file.Close();os.Remove(script);return nil,err}
 if err=file.Close();err!=nil {os.Remove(script);return nil,err}
 cmd:=exec.Command(binary,script,home,cwd)
 cmd.Dir=cwd
 cmd.Env=bunGuestEnv(home)
 // Extension libraries expect platform stderr logging; stdout is RPC only.
 cmd.Stderr=os.Stderr
 input,err:=cmd.StdinPipe()
 if err!=nil{os.Remove(script);return nil,err}
 output,err:=cmd.StdoutPipe()
 if err!=nil{input.Close();os.Remove(script);return nil,err}
 if err=cmd.Start();err!=nil {input.Close();os.Remove(script);return nil,err}
 g:=&BunGuest{cmd:cmd,input:input,output:bufio.NewScanner(output),done:make(chan error,1),script:script,cwd:cwd}
 g.output.Buffer(make([]byte,64*1024),16<<20)
 go func(){g.done<-cmd.Wait()}()
 var reply bunReply
 if err=g.read(&reply,30*time.Second);err!=nil {
  g.Close()
  return nil,fmt.Errorf("Bun guest startup failed: %w",err)
 }
 if reply.Kind!="ready" {g.Close();return nil,fmt.Errorf("Bun guest missing ready response: %q",reply.Kind)}
 g.accept(reply)
 return g,nil
}
func (g *BunGuest) read(out *bunReply,timeout time.Duration) error {
 watchdog:=time.AfterFunc(timeout,func(){_ = g.cmd.Process.Kill()})
 defer watchdog.Stop()
 if !g.output.Scan() {
  if err:=g.output.Err();err!=nil{return err}
  return errors.New("Bun guest stopped without a response")
 }
 if err:=json.Unmarshal(g.output.Bytes(),out);err!=nil{return fmt.Errorf("Bun JSONL protocol: %w",err)}
 if out.Error!="" {return fmt.Errorf("Bun guest: %s",out.Error)}
 return nil
}
func (g *BunGuest) accept(reply bunReply){
 g.catalog=append([]Tool(nil),reply.Tools...)
 g.generation=reply.Generation
 g.warnings=append(g.warnings,reply.Warnings...)
}
func (g *BunGuest) request(kind string, data map[string]any)(bunReply,error){
 g.next++
 data["id"]=g.next
 data["kind"]=kind
 line,err:=json.Marshal(data)
 if err!=nil{return bunReply{},err}
 if _,err=g.input.Write(append(line,'\n'));err!=nil{return bunReply{},err}
 var reply bunReply
 if err=g.read(&reply,60*time.Second);err!=nil{return reply,err}
 if reply.ID!=g.next {return reply,fmt.Errorf("Bun guest reply id %d, expected %d",reply.ID,g.next)}
 g.accept(reply)
 return reply,nil
}
func(g *BunGuest) Diagnostics() []string{
 g.mu.Lock()
 defer g.mu.Unlock()
 return append([]string(nil),g.warnings...)
}
func(g *BunGuest) Catalog()([]Tool,uint64){
 g.mu.Lock()
 defer g.mu.Unlock()
 return append([]Tool(nil),g.catalog...),g.generation
}
func(g *BunGuest) Emit(raw []byte)error{
 g.mu.Lock()
 defer g.mu.Unlock()
 events,err:=g.events.Translate(raw)
 if err!=nil{return err}
 if len(events)==0{return nil}
 _,err=g.request("event",map[string]any{"events":events})
 return err
}
func(g *BunGuest) Execute(name,callID string,arguments json.RawMessage)Result{
 g.mu.Lock()
 defer g.mu.Unlock()
 if len(arguments)==0{arguments=json.RawMessage("{}")}
 reply,err:=g.request("execute",map[string]any{"name":name,"callId":callID,"arguments":arguments})
 if err!=nil{return Result{Content:err.Error()}}
 return reply.Result
}
func(g *BunGuest) Close(){
 g.closeOnce.Do(func(){
  _=g.input.Close()
  if g.cmd.Process!=nil{_ = g.cmd.Process.Kill()}
  select{case <-g.done:case <-time.After(3*time.Second):}
  _=os.Remove(g.script)
 })
}
// Keep compiler checks for the guest contract in the package that owns it.
var _ RuntimeGuest = (*Guest)(nil)
var _ RuntimeGuest = (*BunGuest)(nil)
