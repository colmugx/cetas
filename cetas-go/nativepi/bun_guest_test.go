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

// pi-web-access invokes pi.exec to open its local Curator URL on macOS
// and Windows. Reject arbitrary commands/remote URLs without spawning
// anything, and deliver lifecycle events from real native frame boundaries.
func TestBunGuestCuratorBrowserAndLifecycleBridge(t *testing.T) {
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
		filepath.Join(dir, "dist", "index.js"): `export default function(pi) {
  const sequence = [];
  pi.on("tool_call", event => sequence.push("tool_call:" + event.toolCallId + ":" +
    (event.parentToolCallId ?? "root") + ":" + event.toolName));
  for (const name of ["session_start", "before_agent_start", "agent_start",
    "session_tree", "turn_start"]) {
    pi.on(name, event => sequence.push(event.type));
  }
  pi.registerCommand("bridge-check", {
    description:"Probe local Curator launcher and lifecycle hooks",
    async handler(_args, ctx) {
      const arbitrary = await pi.exec("sh", ["-c", "echo should-not-run"]);
      const remote = await pi.exec("open", ["https://example.com/"]);
      const unsafe = await pi.exec("cmd", ["/c", "start", "", "http://example.com/"]);
      if (arbitrary.code === 0 || remote.code === 0 || unsafe.code === 0) {
        throw new Error("Pi exec allowed an unsupported command or URL");
      }
      ctx.ui.notify("exec:function; events:" + sequence.join(","));
    },
  });
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
	if err := g.Emit([]byte(`{"type":"turn.started"}`)); err != nil {
		t.Fatal(err)
	}
	if err := g.Emit([]byte(`{"type":"session.switched"}`)); err != nil {
		t.Fatal(err)
	}
	if err := g.Emit([]byte(`{"type":"tool.started","tool_call_id":"nested-1","parent_tool_call_id":"outer-1","tool_name":"web_search","arguments":{"query":"cetas"}}`)); err != nil {
		t.Fatal(err)
	}
	out := g.RunCommand("pi:bridge-check", "")
	if out.Type != "success" {
		t.Fatalf("Pi browser compatibility command failed: %#v", out)
	}
	if !strings.Contains(out.Feedback, "events:session_start,before_agent_start,agent_start,turn_start,session_tree,tool_call:nested-1:outer-1:web_search") {
		t.Fatalf("Pi lifecycle events missing or reordered: %#v", out)
	}
	for _, warning := range g.Diagnostics() {
		if strings.Contains(warning, "before_agent_start") || strings.Contains(warning, "session_tree") || strings.Contains(warning, "tool_call") {
			t.Fatalf("supported Pi lifecycle hook warned: %s", warning)
		}
	}
}

// Pi custom entries are queued until the native SessionPort confirms a save;
// background sendMessage is never silently dropped after a command returns.
func TestBunGuestCustomEntryAndFollowUpOutbox(t *testing.T) {
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
		filepath.Join(dir, "dist", "index.js"): `export default function(pi) {
 pi.registerCommand("store-check", {
   description:"Queue custom data and host-owned follow-up",
   handler(_args, ctx) {
     pi.appendEntry("web-search-results",{id:"search-1",timestamp:1234,queries:[]});
     pi.sendMessage({content:[{type:"text",text:"Search completed"}],display:true},
       {triggerTurn:true,deliverAs:"followUp"});
     ctx.ui.notify("branch:" + ctx.sessionManager.getBranch().length +
       ";session:" + ctx.sessionManager.getSessionId());
   },
 });
 pi.registerTool({
   name:"pi_store_probe",description:"Read restored entries",
   parameters:{type:"object",properties:{}},
   execute(_id,_args,_signal,_onUpdate,ctx) {
     const entries=ctx.sessionManager.getBranch();
     return {content:[{type:"text",text:ctx.sessionManager.getSessionId()+
       ":"+entries.length+":"+entries[0]?.customType}]};
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
	snapshot := json.RawMessage(`{"session_id":"session-1","entries":[]}`)
	if err := g.UpdateSession(snapshot); err != nil {
		t.Fatalf("restore Pi session: %v", err)
	}
	out := g.RunCommand("pi:store-check", "")
	if out.Type != "success" || !strings.Contains(out.Feedback, "branch:1;session:session-1") {
		t.Fatalf("Pi appendEntry not reflected in session branch: %#v", out)
	}
	pending, err := g.PendingOutbox()
	if err != nil {
		t.Fatal(err)
	}
	if len(pending.Entries) != 1 || pending.Entries[0].CustomType != "web-search-results" ||
		len(pending.Messages) != 1 || pending.Messages[0].Text != "Search completed" ||
		!pending.Messages[0].TriggerTurn || pending.Messages[0].DeliverAs != "followUp" {
		t.Fatalf("unexpected Pi outbox: %#v", pending)
	}
	if err := g.AckOutbox([]string{pending.Entries[0].ID}, []string{pending.Messages[0].ID}); err != nil {
		t.Fatalf("ack Pi outbox: %v", err)
	}
	pending, err = g.PendingOutbox()
	if err != nil {
		t.Fatal(err)
	}
	if len(pending.Entries) != 0 || len(pending.Messages) != 0 {
		t.Fatalf("acknowledged Pi outbox was not drained: %#v", pending)
	}
	result := g.Execute("pi_store_probe", "call-1", json.RawMessage(`{}`))
	if !result.OK || result.Content != "session-1:1:web-search-results" {
		t.Fatalf("Pi custom entry disappeared after native acknowledgement: %#v", result)
	}
	restored := json.RawMessage(`{"session_id":"session-1","entries":[{"customType":"web-search-results","data":{"id":"search-2","queries":[]}}]}`)
	if err := g.UpdateSession(restored); err != nil {
		t.Fatalf("update restored entries: %v", err)
	}
	result = g.Execute("pi_store_probe", "call-2", json.RawMessage(`{}`))
	if !result.OK || result.Content != "session-1:1:web-search-results" {
		t.Fatalf("Pi stored entry was not restored from host: %#v", result)
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
