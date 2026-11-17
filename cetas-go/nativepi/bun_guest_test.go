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

// The Pi command face is distinct from the model-visible tool catalog.
// Both native /pi:<name> and shortcut keys invoke the original JS handlers.
func TestBunGuestPiCommandAndShortcutBridge(t *testing.T) {
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
		filepath.Join(dir, "package.json"): `{"name":"fixture","pi":{"extensions":["./dist"]}}`,
		filepath.Join(dir, "dist", "index.js"): `export default function(pi) {
  pi.registerCommand("websearch", {
    description: "Open web search curator",
    async handler(args, ctx) {
      ctx.ui.notify("search:" + args + ":" + ctx.cwd, "info");
    },
  });
  pi.registerShortcut("ctrl+shift+f9", {
    description: "Web search shortcut",
    handler(ctx) { ctx.ui.notify("shortcut:" + ctx.cwd, "info"); },
  });
}`,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	g, err := OpenBun(binary, home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	commands, revision := g.Commands()
	if revision != 2 || len(commands) != 2 ||
		commands[0].ID != "pi:websearch" || !commands[0].Visible ||
		commands[1].ID != "pi:#ctrl+shift+f9" || commands[1].Visible ||
		commands[1].Shortcut != "ctrl+shift+f9" {
		t.Fatalf("Pi command catalog = %#v, revision %d, warnings %v", commands, revision, g.Diagnostics())
	}
	if defs, _ := g.Catalog(); len(defs) != 0 {
		t.Fatalf("Commands were leaked as model tools: %#v", defs)
	}
	out := g.RunCommand("pi:websearch", "two words")
	if out.Type != "success" || !strings.Contains(out.Feedback, "search:two words:"+home) {
		t.Fatalf("Pi command handler failed: %#v", out)
	}
	out = g.RunCommand("pi:#ctrl+shift+f9", "")
	if out.Type != "success" || !strings.Contains(out.Feedback, "shortcut:"+home) {
		t.Fatalf("Pi shortcut handler failed: %#v", out)
	}
	out = g.RunCommand("pi:missing", "")
	if out.Type != "failure" {
		t.Fatalf("Unknown Pi command succeeded: %#v", out)
	}
}

// A real Pi extension such as pi-web-access reads modelRegistry.getAvailable()
// during /pi:websearch startup. The native guest cannot supply Pi models or
// credentials without a Posoco provider bridge; these fields must be present,
// accurately empty, and never expose the native host's provider secrets.
func TestBunGuestPiCommandModelRegistryContext(t *testing.T) {
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
		filepath.Join(dir, "package.json"): `{"name":"fixture","pi":{"extensions":["./dist"]}}`,
		filepath.Join(dir, "dist", "index.js"): `export default function(pi) {
  pi.registerCommand("websearch", {
    description: "Probe pi-web-access's model registry usage",
    async handler(_args, ctx) {
      const summaryContext = {
        model: ctx.model,
        modelRegistry: ctx.modelRegistry,
        sessionManager: ctx.sessionManager,
        scopedModels: ctx.scopedModels,
      };
      const available = summaryContext.modelRegistry.getAvailable();
      const all = summaryContext.modelRegistry.getAll();
      const found = summaryContext.modelRegistry.find("openai", "test-model");
      const auth = await summaryContext.modelRegistry.getApiKeyAndHeaders({provider:"openai",id:"test-model"});
      ctx.ui.notify("available:" + available.length + ",all:" + all.length +
        ",found:" + String(found?.id) + ",auth:" + auth.ok +
        ",scope:" + summaryContext.scopedModels.length +
        ",active:" + (ctx.model?.provider ?? "none") + "/" + (ctx.model?.id ?? "none"));
    },
  });
  pi.registerTool({
    name:"probe_context",
    description:"Check the model registry in tool executions",
    parameters:{type:"object",properties:{}},
    async execute(_id, _args, _signal, _onUpdate, ctx) {
      return {content:[{type:"text",text:"available:"+ctx.modelRegistry.getAvailable().length}]};
    },
  });
}`,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	g, err := OpenBun(binary, home, home)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	out := g.RunCommand("pi:websearch", "")
	if out.Type != "success" || !strings.Contains(out.Feedback, "available:0,all:0,found:undefined,auth:false,scope:0") {
		t.Fatalf("Pi command model registry context unavailable: %#v, warnings: %v", out, g.Diagnostics())
	}
	result := g.Execute("probe_context", "call-1", json.RawMessage(`{}`))
	if !result.OK || result.Content != "available:0" {
		t.Fatalf("Pi tool model registry context unavailable: %#v", result)
	}

	// The real Cetas model picker publishes a session-scoped snapshot.
	// Project metadata only, never credentials, then verify both command
	// and tool contexts switch from the empty bootstrap state to real data.
	snapshot := json.RawMessage(`{"active":"openai/test-model","slots":[{"id":"openai/test-model","provider":"openai","model":"test-model","label":"Test model","context_window":8192}]}`)
	if err := g.UpdateModels(snapshot); err != nil {
		t.Fatalf("update Pi model snapshot: %v", err)
	}
	out = g.RunCommand("pi:websearch", "")
	if out.Type != "success" || !strings.Contains(out.Feedback, "available:1,all:1,found:test-model,auth:false,scope:0,active:openai/test-model") {
		t.Fatalf("Pi command model snapshot missing: %#v", out)
	}
	result = g.Execute("probe_context", "call-2", json.RawMessage(`{}`))
	if !result.OK || result.Content != "available:1" {
		t.Fatalf("Pi tool model snapshot missing: %#v", result)
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
