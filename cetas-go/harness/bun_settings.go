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

type experimentalSettings struct { BunRuntime bool `json:"bun_runtime"` }
func experimentalSettingsPath(home string) string {return filepath.Join(home,".cetas","experimental.json")}
func readExperimentalSettings(home string)(experimentalSettings,error) {
 data,err:=os.ReadFile(experimentalSettingsPath(home))
 if os.IsNotExist(err){return experimentalSettings{},nil}
 if err!=nil{return experimentalSettings{},err}
 var cfg experimentalSettings
 if err=json.Unmarshal(data,&cfg);err!=nil{return cfg,fmt.Errorf("experimental settings: %w",err)}
 return cfg,nil
}
func bunGuestEnabled(home string)(bool,error) {
 cfg,err:=readExperimentalSettings(home)
 return cfg.BunRuntime,err
}
func setBunGuestEnabled(home string,enabled bool) error {
 cfg,err:=readExperimentalSettings(home)
 if err!=nil{return err}
 cfg.BunRuntime=enabled
 body,err:=json.MarshalIndent(cfg,"","  ")
 if err!=nil{return err}
 path:=experimentalSettingsPath(home)
 if err=os.MkdirAll(filepath.Dir(path),0700);err!=nil{return err}
 tmp,err:=os.CreateTemp(filepath.Dir(path),".experimental-*.tmp")
 if err!=nil{return err}
 defer os.Remove(tmp.Name())
 if _,err=tmp.Write(append(body,'\n'));err!=nil{tmp.Close();return err}
 if err=tmp.Chmod(0600);err!=nil{tmp.Close();return err}
 if err=tmp.Close();err!=nil{return err}
 return os.Rename(tmp.Name(),path)
}
func verifyBunBinary(ctx context.Context,path string)error{
 ctx,cancel:=context.WithTimeout(ctx,10*time.Second)
 defer cancel()
 out,err:=exec.CommandContext(ctx,path,"--version").CombinedOutput()
 if err!=nil{return fmt.Errorf("Bun cannot start: %w (%s)",err,strings.TrimSpace(string(out)))}
 if strings.TrimSpace(string(out))!=experimentalBunVersion{return fmt.Errorf("Bun version %q != %s",strings.TrimSpace(string(out)),experimentalBunVersion)}
 return nil
}
