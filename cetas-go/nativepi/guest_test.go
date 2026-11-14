package nativepi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sample = `export default function(pi) {
  pi.registerTool({name: "pi_echo", description: "Echo the supplied text",
    parameters: {type:"object",properties:{text:{type:"string",minLength:1}},required:["text"]},
    async execute(callId, params) {
      const text = await Promise.resolve(params.text);
      return {content:[{type:"text",text:"echo:"+text}]};
    }
  });
}`

func writeFixture(t *testing.T) (string,string) {
	t.Helper()
	home:=t.TempDir()
	dir:=filepath.Join(home,".cetas","pi-packages","fixture")
	if err:=os.MkdirAll(dir,0700);err!=nil{t.Fatal(err)}
	for path,body:=range map[string]string{
		filepath.Join(home,".cetas","pi-packages.json"):`{"packages":["fixture"]}`,
		filepath.Join(dir,"package.json"):`{"name":"fixture","pi":{"extensions":["./index.mjs"]}}`,
		filepath.Join(dir,"index.mjs"):sample,
	} {
		if err:=os.WriteFile(path,[]byte(body),0600);err!=nil{t.Fatal(err)}
	}
	return home,dir
}

func TestGuestUnmodifiedPiRegistrationAndAsyncTool(t *testing.T){
	home,_:=writeFixture(t)
	g,err:=Open(home,home);if err!=nil{t.Fatal(err)}
	defer g.Close()
	defs,ver:=g.Catalog()
	if ver==0||len(defs)!=1||defs[0].Name!="pi_echo" {t.Fatalf("catalog: %#v version %d",defs,ver)}
	if !strings.Contains(string(defs[0].Parameters),`"minLength":1`){t.Fatalf("schema weakened: %s",defs[0].Parameters)}
	res:=g.Execute("pi_echo","call1",json.RawMessage(`{"text":"hello"}`))
	if !res.OK||res.Content!="echo:hello" {t.Fatalf("tool result: %#v",res)}
}

func TestGuestRequiresAllowlist(t *testing.T) {
	g,err:=Open(t.TempDir(),t.TempDir());if err!=nil{t.Fatal(err)}
	defer g.Close()
	defs,_:=g.Catalog();if len(defs)!=0{t.Fatal("loaded unapproved Pi plugins")}
}

func TestGuestRejectsPackageEscape(t *testing.T){
	home,dir:=writeFixture(t)
	if err:=os.WriteFile(filepath.Join(dir,"package.json"),[]byte(`{"name":"fixture","pi":{"extensions":["../../escape.js"]}}`),0600);err!=nil{t.Fatal(err)}
	_,err:=Open(home,home)
	if err==nil{t.Fatal("accepted escaping module path")}
}
