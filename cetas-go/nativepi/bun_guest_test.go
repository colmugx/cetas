package nativepi

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// This test runs in the existing Go suite when Bun is already available;
// it never downloads a runtime or adds a dedicated extension CI.
func TestBunGuestUnmodifiedNodeImportsAndAsyncTool(t *testing.T) {
	binary := os.Getenv("CETAS_TEST_BUN")
	if binary == "" {
		var err error
		binary, err = exec.LookPath("bun")
		if err != nil {
			t.Skip("Bun is not installed")
		}
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	dir := filepath.Join(home, ".cetas", "pi-packages", "node_modules", "fixture")
	if err = os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for path, contents := range map[string]string{
		filepath.Join(home, ".cetas", "pi-packages.json"): `{"packages":["fixture"]}`,
		filepath.Join(dir, "package.json"):                `{"name":"fixture","pi":{"extensions":["./dist"]}}`,
		filepath.Join(dir, "dist", "index.ts"): `
import { createHash } from "node:crypto";
export default function(pi: any) {
 const lifecycle: string[] = [];
 pi.on("turn_start", e => lifecycle.push(e.type));
 pi.registerTool({
  name:"pi_bun_echo",
  description:"Bun guest Node builtins + async test",
  parameters:{type:"object",properties:{text:{type:"string"}}},
  async execute(_id: string, params: any) {
   await Promise.resolve();
   return {content:[{type:"text",text:createHash("sha256").update(params.text).digest("hex")+":"+lifecycle.join(",")}]};
  }
 });
}
`,
	} {
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	g, err := OpenBun(binary, home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	defs, rev := g.Catalog()
	if rev == 0 || len(defs) != 1 || defs[0].Name != "pi_bun_echo" {
		t.Fatalf("Bun guest catalog: %v / %d, warnings %v", defs, rev, g.Diagnostics())
	}
	if err = g.Emit([]byte(`{"type":"turn.started"}`)); err != nil {
		t.Fatal(err)
	}
	result := g.Execute("pi_bun_echo", "tool-1", json.RawMessage(`{"text":"abc"}`))
	if !result.OK || !strings.HasSuffix(result.Content, ":turn_start") {
		t.Fatalf("Bun guest tool failed: %#v", result)
	}
	if !strings.HasPrefix(result.Content, "ba7816bf8f01cfea") {
		t.Fatalf("Node crypto not executed: %s", result.Content)
	}
}
