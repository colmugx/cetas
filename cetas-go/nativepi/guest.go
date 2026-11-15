// Package nativepi runs allowlisted, unmodified Pi extension modules in
// process, using moejs. It is a foreign JavaScript guest, not an Agent kernel:
// only the MoonBit/Posoco ToolContributions and Agent run-loop may expose or
// execute the registered tools.
package nativepi

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/MoeForge/moejs"
	"github.com/MoeForge/moejs/eventloop"
)

// Tool is the guest's catalog descriptor. Parameters must not be weakened,
// projected or trusted as already validated: the Posoco kernel owns validation.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

type Result struct {
	OK      bool `json:"ok"`
	Content string `json:"content"`
	Details any `json:"details,omitempty"`
}

// Guest is one session's private JS VM. No other session shares callbacks.
type Guest struct {
	mu      sync.Mutex
	cwd     string
	entries []*entry
	names   map[string]*registered
	active  map[string]bool
	version uint64
	events EventBridge
}

type registered struct {
	Tool
	callback moejs.Value
	owner    *entry
}

type entry struct {
	runtime  *moejs.Runtime
	loop     *eventloop.Loop
	guest    *Guest
	handlers map[string][]moejs.Value
}

// Open reads the same deny-by-default allowlist used by cetas-js. Missing or
// malformed config means no plugins. Failed allowlisted packages are reported
// rather than suppressed. Modules and imports may only resolve beneath the
// allowlisted package directory; bare and node:* imports are not granted.
func Open(home, cwd string) (*Guest, error) {
	g := &Guest{cwd: cwd, names: make(map[string]*registered)}
	root := filepath.Join(home, ".cetas", "pi-packages")
	allowPath := filepath.Join(home, ".cetas", "pi-packages.json")
	config, err := os.ReadFile(allowPath)
	if errors.Is(err, os.ErrNotExist) {
		return g, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read Pi allowlist: %w", err)
	}
	var allow struct{ Packages []string `json:"packages"` }
	if err := json.Unmarshal(config, &allow); err != nil {
		return nil, fmt.Errorf("parse Pi allowlist: %w", err)
	}
	for _, name := range allow.Packages {
		if !validPackageName(name) {
			return nil, fmt.Errorf("invalid Pi allowlist package name %q", name)
		}
		dir := filepath.Join(root, name)
		if err := g.loadPackage(dir, name); err != nil {
			return nil, err
		}
	}
	return g, nil
}

func validPackageName(name string) bool {
	return name != "" && name != "." && name != ".." &&
		!strings.ContainsAny(name, "/\\:\x00")
}

func (g *Guest) loadPackage(dir, expected string) error {
	manifestRaw, err := os.ReadFile(filepath.Join(dir, "package.json"))
	if err != nil {
		return fmt.Errorf("Pi package %q: %w", expected, err)
	}
	var manifest struct {
		Name string `json:"name"`
		Pi struct { Extensions []string `json:"extensions"` } `json:"pi"`
	}
	if err := json.Unmarshal(manifestRaw, &manifest); err != nil {
		return fmt.Errorf("Pi package %q manifest: %w", expected, err)
	}
	if manifest.Name != expected {
		return fmt.Errorf("Pi package name mismatch %q != %q", manifest.Name, expected)
	}
	for _, spec := range manifest.Pi.Extensions {
		if err := g.loadEntry(dir, spec); err != nil {
			return fmt.Errorf("Pi package %q entry %q: %w", expected, spec, err)
		}
	}
	return nil
}

func allowedModule(root, path string) (string, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil { return "", err }
	path, err = filepath.EvalSymlinks(path)
	if err != nil { return "", err }
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("module escapes allowlisted Pi package: %q", path)
	}
	if ext := filepath.Ext(path); ext != ".js" && ext != ".mjs" && ext != ".ts" {
		return "", fmt.Errorf("unsupported Pi module extension %q", ext)
	}
	return path, nil
}

func (g *Guest) loadEntry(root, spec string) error {
	if !strings.HasPrefix(spec, "./") {
		return fmt.Errorf("Pi entry must be package-relative: %q", spec)
	}
	path, err := allowedModule(root, filepath.Join(root, spec))
	if err != nil { return err }
	mods := map[string]*moejs.Module{}
	var compileFile func(string) (*moejs.Module, error)
	compileFile = func(path string) (*moejs.Module, error) {
		if mod := mods[path]; mod != nil { return mod, nil }
		src, err := os.ReadFile(path)
		if err != nil { return nil, err }
		var mod *moejs.Module
		if filepath.Ext(path) == ".ts" {
			mod, err = moejs.CompileTS(path, string(src))
		} else {
			mod, err = moejs.Compile(path, string(src))
		}
		if err == nil { mods[path] = mod }
		return mod, err
	}
	mod, err := compileFile(path)
	if err != nil { return err }
	mod, err = moejs.Link(mod, func(from moejs.Referrer, specifier string) (*moejs.Module, error) {
		if !strings.HasPrefix(specifier, "./") && !strings.HasPrefix(specifier, "../") {
			return nil, fmt.Errorf("Pi guest import %q is not permitted", specifier)
		}
		target, err := allowedModule(root, filepath.Join(filepath.Dir(from.Name()), specifier))
		if err != nil { return nil, err }
		return compileFile(target)
	})
	if err != nil { return err }

	rt := moejs.NewRuntime(moejs.Options{MemoryLimit: 64 << 20})
	loop, err := eventloop.New(rt, eventloop.Options{})
	if err != nil { return err }
	e := &entry{runtime: rt, loop: loop, guest: g, handlers: make(map[string][]moejs.Value)}
	api, err := e.makeAPI()
	if err != nil { return err }
	if err := loop.Run(func(rt *moejs.Runtime) error {
		if err := rt.Load(mod); err != nil { return err }
		fn, ok := rt.Export("default")
		if !ok { return errors.New("Pi entry has no default export") }
		_, err := rt.CallFunction(fn, moejs.Undefined(), api)
		return err
	}); err != nil { return err }
	g.entries = append(g.entries, e)
	return nil
}

func (e *entry) makeAPI() (moejs.Value, error) {
	rt := e.runtime
	register := moejs.NativeFunc(func(_ *moejs.Realm, _ moejs.Value, args []moejs.Value) (moejs.Value, error) {
		obj := moejs.Arg(args, 0)
		nameV, err := rt.Get(obj, "name")
		if err != nil { return moejs.Undefined(), err }
		name := nameV.String()
		if name == "" { return moejs.Undefined(), errors.New("Pi tool name must not be empty") }
		if _, exists := e.guest.names[name]; exists {
			return moejs.Undefined(), fmt.Errorf("duplicate Pi tool %q", name)
		}
		desc, err := rt.Get(obj, "description")
		if err != nil { return moejs.Undefined(), err }
		param, err := rt.Get(obj, "parameters")
		if err != nil { return moejs.Undefined(), err }
		var schema []byte
		if param.IsUndefined() {
			schema = []byte(`{"type":"object","properties":{}}`)
		} else if schema, err = rt.AppendJSON(nil, param); err != nil {
			return moejs.Undefined(), err
		}
		callback, err := rt.Get(obj, "execute")
		if err != nil { return moejs.Undefined(), err }
		if !callback.IsObject() {
			return moejs.Undefined(), fmt.Errorf("Pi tool %q needs execute()", name)
		}
		e.guest.names[name] = &registered{
			Tool: Tool{Name:name, Description:desc.String(), Parameters:append(json.RawMessage(nil),schema...)},
			callback: callback, owner: e,
		}
		// Pi's live registry appends newly registered tools to an explicit set.
		if e.guest.active != nil { e.guest.active[name] = true }
		e.guest.version++
		return moejs.Undefined(), nil
	})
	getAll := moejs.NativeFunc(func(_ *moejs.Realm, _ moejs.Value, _ []moejs.Value) (moejs.Value, error) {
		defs := e.guest.catalog(false)
		out := make([]map[string]string, len(defs))
		for i, def := range defs {out[i] = map[string]string{"name":def.Name,"description":def.Description}}
		return rt.FromGo(out)
	})
	getActive := moejs.NativeFunc(func(_ *moejs.Realm, _ moejs.Value, _ []moejs.Value) (moejs.Value, error) {
		defs := e.guest.catalog(true)
		names := make([]string,0,len(defs))
		for _, def := range defs { names=append(names,def.Name) }
		return rt.FromGo(names)
	})
	setActive := moejs.NativeFunc(func(_ *moejs.Realm, _ moejs.Value, args []moejs.Value) (moejs.Value, error) {
		raw, err := rt.ToGo(moejs.Arg(args, 0))
		if err != nil { return moejs.Undefined(),err }
		arr, ok := raw.([]any)
		if !ok { return moejs.Undefined(), errors.New("setActiveTools expects an array") }
		next := map[string]bool{}
		for _, item := range arr { if n,ok:=item.(string);ok && e.guest.names[n]!=nil {next[n]=true} }
		e.guest.active=next
		e.guest.version++
		return moejs.Undefined(),nil
	})
	on := moejs.NativeFunc(func(_ *moejs.Realm, _ moejs.Value, args []moejs.Value) (moejs.Value, error) {
		eventName := moejs.Arg(args, 0).String()
		if !supportedPiEvent(eventName) {
			// Request-transforming Pi hooks have no equivalent in Posoco's
			// current public APIs. Never accept them and silently do nothing.
			return moejs.Undefined(), fmt.Errorf("Pi event %q is unsupported by cetas-go", eventName)
		}
		handler := moejs.Arg(args, 1)
		if !handler.IsObject() {
			return moejs.Undefined(), errors.New("Pi event handler must be callable")
		}
		e.handlers[eventName] = append(e.handlers[eventName], handler)
		return moejs.Undefined(), nil
	})
	return rt.FromGo(map[string]any{
		"registerTool":register,"getAllTools":getAll,"getActiveTools":getActive,
		"setActiveTools":setActive,"on":on,
	})
}

func (g *Guest) catalog(active bool) []Tool {
	keys:=make([]string,0,len(g.names))
	for k:=range g.names {keys=append(keys,k)}
	sort.Strings(keys)
	tools:=make([]Tool,0,len(keys))
	for _,name:=range keys {
		if active && g.active != nil && !g.active[name] { continue }
		tools=append(tools,g.names[name].Tool)
	}
	return tools
}

func (g *Guest) Catalog() ([]Tool, uint64) {
	g.mu.Lock();defer g.mu.Unlock()
	return g.catalog(true),g.version
}

// Execute invokes the actual extension closure inside its own VM. A pending
// Promise whose only completion requires an unprovided host API is reported as
// unsupported instead of fabricating a successful tool execution.
func (g *Guest) Execute(name,callID string,args json.RawMessage) (out Result) {
	g.mu.Lock();defer g.mu.Unlock()
	reg:=g.names[name]
	if reg==nil { return Result{Content:"unknown Pi tool: "+name} }
	var value moejs.Value
	err:=reg.owner.loop.Run(func(rt *moejs.Runtime) error {
		argument,err:=rt.ParseJSON(args)
		if err!=nil {return err}
		ctx,err:=rt.FromGo(map[string]any{"cwd":g.cwd,"hasUI":false,"mode":"json"})
		if err!=nil {return err}
		value,err=rt.CallFunction(reg.callback,moejs.Undefined(),moejs.String(callID),argument,moejs.Undefined(),moejs.Undefined(),ctx)
		return err
	})
	if err!=nil { return Result{Content:err.Error()} }
	if state,result,ok:=moejs.PromiseResult(value);ok {
		if state==moejs.PromisePending {return Result{Content:"Pi tool promise never settled (unsupported guest host capability)"}}
		if state==moejs.PromiseRejected {return Result{Content:"Pi tool rejected: "+result.String()}}
		value=result
	}
	raw,err:=reg.owner.runtime.AppendJSON(nil,value)
	if err!=nil{return Result{Content:err.Error()}}
	var parsed struct{
		Content []struct{Type string `json:"type"`;Text string `json:"text"` } `json:"content"`
		Details any `json:"details"`
		IsError bool `json:"isError"`
	}
	if err:=json.Unmarshal(raw,&parsed);err!=nil{return Result{Content:err.Error()}}
	var parts []string
	for _,p:=range parsed.Content {if p.Type=="text"{parts=append(parts,p.Text)}}
	return Result{OK:!parsed.IsError,Content:strings.Join(parts,"\n"),Details:parsed.Details}
}

func (g *Guest) Close() {
	g.mu.Lock();defer g.mu.Unlock()
	for _,e:=range g.entries {e.loop.Terminate()}
	g.entries=nil
	g.names=nil
}
