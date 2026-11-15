package harness

import (
 "encoding/json"
 "os"
 "path/filepath"
 "testing"
)

func TestEnsurePiUmbrellaSuppliesHostPeer(t *testing.T) {
 root:=filepath.Join(t.TempDir(),"pi-packages")
 if err:=ensurePiUmbrella(root);err!=nil{t.Fatal(err)}
 check:=func()map[string]any{
  t.Helper()
  data,err:=os.ReadFile(filepath.Join(root,"package.json"))
  if err!=nil{t.Fatal(err)}
  var manifest map[string]any
  if err=json.Unmarshal(data,&manifest);err!=nil{t.Fatal(err)}
  return manifest
 }
 first:=check()
 deps:=first["dependencies"].(map[string]any)
 if deps[piTuiHostPeer]!=piTuiHostVersion{t.Fatalf("missing host peer: %#v",deps)}
 deps["pi-web-access"]="^0.48.0"
 deps[piTuiHostPeer]="1.3.0"
 first["custom"]=map[string]any{"retained":true}
 encoded,err:=json.Marshal(first)
 if err!=nil{t.Fatal(err)}
 if err=os.WriteFile(filepath.Join(root,"package.json"),encoded,0600);err!=nil{t.Fatal(err)}
 if err=ensurePiUmbrella(root);err!=nil{t.Fatal(err)}
 preserved:=check()
 actual:=preserved["dependencies"].(map[string]any)
 if actual[piTuiHostPeer]!="1.3.0"||actual["pi-web-access"]!="^0.48.0"{
  t.Fatalf("existing dependencies were overwritten: %#v",actual)
 }
 if preserved["custom"].(map[string]any)["retained"]!=true{t.Fatal("lost custom fields")}
}

func TestEnsurePiUmbrellaRejectsMalformedManifest(t *testing.T) {
 root:=t.TempDir()
 if err:=os.WriteFile(filepath.Join(root,"package.json"),[]byte(`{"dependencies":[]}`),0600);err!=nil{t.Fatal(err)}
 if err:=ensurePiUmbrella(root);err==nil{t.Fatal("invalid dependencies accepted")}
}
