package harness

import (
 "os"
 "path/filepath"
 "runtime"
 "strings"
 "testing"
)

func TestExperimentalBunTargetsAndPinnedChecksums(t *testing.T) {
 cases:=[]struct{os,arch,archive string}{
  {"darwin","arm64","bun-darwin-aarch64.zip"},
  {"linux","amd64","bun-linux-x64-baseline.zip"},
  {"linux","arm64","bun-linux-aarch64.zip"},
  {"windows","amd64","bun-windows-x64-baseline.zip"},
 }
 for _,c:=range cases {
  got,err:=bunArtifactFor(c.os,c.arch)
  if err!=nil||got!=c.archive {t.Fatalf("%s/%s: %s %v",c.os,c.arch,got,err)}
  if len(experimentalBunChecksums[got])!=64 {t.Fatalf("missing pinned checksum for %s",got)}
 }
 if _,err:=bunArtifactFor("plan9","386");err==nil {t.Fatal("unsupported target accepted")}
}

func TestExperimentalBunIsOptIn(t *testing.T) {
 home:=t.TempDir()
 path,ready,err:=bunPrepared(home)
 if err!=nil {t.Skipf("unsupported runtime target: %v",err)}
 if ready {t.Fatal("unexpected preinstalled Bun")}
 if !strings.HasPrefix(path,filepath.Join(home,".cetas","runtimes","bun")) {t.Fatalf("cache escaped home: %s",path)}
 if err=os.MkdirAll(filepath.Dir(path),0700);err!=nil{t.Fatal(err)}
 if err=os.WriteFile(path,[]byte("bun placeholder"),0700);err!=nil{t.Fatal(err)}
 got,ready,err:=bunPrepared(home)
 if err!=nil||!ready||got!=path {t.Fatalf("cache presence: %s %v %v",got,ready,err)}
 _=runtime.GOOS
}
