package harness

import (
 "context"
 "encoding/json"
 "fmt"
 "os"
 "os/exec"
 "path/filepath"
 "strings"
 "time"
)

type piRuntimeSetting struct {
 Engine string `json:"engine"`
}
func bunSettingsPath(home string)string{
 return filepath.Join(home,".cetas","pi-runtime.json")
}
func bunGuestEnabled(home string)(bool,error){
 data,err:=os.ReadFile(bunSettingsPath(home))
 if os.IsNotExist(err){return false,nil}
 if err!=nil{return false,err}
 var cfg piRuntimeSetting
 if err=json.Unmarshal(data,&cfg);err!=nil{return false,fmt.Errorf("Pi runtime settings: %w",err)}
 switch cfg.Engine {
 case "","moejs":return false,nil
 case "bun":return true,nil
 default:return false,fmt.Errorf("unsupported Pi runtime engine %q",cfg.Engine)
 }
}
func setBunGuestEnabled(home string,enabled bool)error {
 engine:="moejs"
 if enabled{engine="bun"}
 content,err:=json.MarshalIndent(piRuntimeSetting{Engine:engine},"","  ")
 if err!=nil{return err}
 path:=bunSettingsPath(home)
 if err=os.MkdirAll(filepath.Dir(path),0700);err!=nil{return err}
 tmp,err:=os.CreateTemp(filepath.Dir(path),".runtime-*.tmp")
 if err!=nil{return err}
 defer os.Remove(tmp.Name())
 if _,err=tmp.Write(append(content,'\n'));err!=nil{tmp.Close();return err}
 if err=tmp.Chmod(0600);err!=nil{tmp.Close();return err}
 if err=tmp.Close();err!=nil{return err}
 return os.Rename(tmp.Name(),path)
}
func verifyBunBinary(ctx context.Context,path string)error {
 check,cancel:=context.WithTimeout(ctx,10*time.Second)
 defer cancel()
 out,err:=exec.CommandContext(check,path,"--version").CombinedOutput()
 if err!=nil{return fmt.Errorf("Bun binary cannot start: %w (%s)",err,strings.TrimSpace(string(out)))}
 if strings.TrimSpace(string(out))!=experimentalBunVersion {
  return fmt.Errorf("Bun binary version %q does not match expected %s",strings.TrimSpace(string(out)),experimentalBunVersion)
 }
 return nil
}
