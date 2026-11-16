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

func TestBunGuestHostModuleBridge(t *testing.T) {
	binary := os.Getenv("CETAS_TEST_BUN")
	if binary == "" {
		var err error
		binary, err = exec.LookPath("bun")
		if err != nil {
			t.Skip("Bun not available")
		}
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	dir := filepath.Join(home, ".cetas", "pi-packages", "node_modules", "fixture")
	for path, content := range map[string]string{
		filepath.Join(home, ".cetas", "pi-packages.json"): `{"packages":["fixture"]}`,
		filepath.Join(dir, "package.json"):                `{"name":"fixture","pi":{"extensions":["./dist"]}}`,
		filepath.Join(dir, "dist", "index.ts"): `import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { truncateFromNestedModule } from "./nested.ts";
export default function(pi: any) {
 pi.registerTool({name:"pi_host_probe",description:"Cetas host modules",parameters:{type:"object",properties:{}},
   execute: async () => ({content:[{type:"text",text:truncateFromNestedModule()+":"+getAgentDir().endsWith(".cetas")}]})});
}`,
		filepath.Join(dir, "dist", "nested.ts"): `import { truncateToWidth } from "@earendil-works/pi-tui";
export function truncateFromNestedModule() {
 return truncateToWidth("abcdef", 3);
}`,
	} {
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	g, err := OpenBun(binary, home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	defs, _ := g.Catalog()
	if len(defs) != 1 || defs[0].Name != "pi_host_probe" {
		t.Fatalf("host module shim missing: %v, warnings: %v", defs, g.Diagnostics())
	}
	out := g.Execute("pi_host_probe", "probe", json.RawMessage("{}"))
	if !out.OK || !strings.Contains(out.Content, ":true") {
		t.Fatalf("host module functionality unavailable: %#v", out)
	}
}

func TestBunGuestEnvironmentConfinesPiConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("OPENAI_API_KEY", "should-not-pass")
	vars := bunGuestEnv(home)
	values := make(map[string]string)
	for _, entry := range vars {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) == 2 {
			values[parts[0]] = parts[1]
		}
	}
	if values["CETAS_HOME"] != home {
		t.Fatalf("missing Cetas home: %q", values["CETAS_HOME"])
	}
	if values["PI_CODING_AGENT_DIR"] != filepath.Join(home, ".cetas") {
		t.Fatalf("Pi config escaped Cetas home: %q", values["PI_CODING_AGENT_DIR"])
	}
	if _, ok := values["OPENAI_API_KEY"]; ok {
		t.Fatal("provider credentials leaked into Bun guest")
	}
}
