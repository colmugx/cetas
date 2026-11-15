package harness

// Pi package management belongs to the Go host: npm never executes on the
// MoonBit scheduler thread, and the allowlist remains deny-by-default.
import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

var piPackageName = regexp.MustCompile(`^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$`)
var piInstallMu sync.Mutex

// Pi extensions import a family of host-owned peers. The Cetas JS mirror
// needs physical copies in the shared umbrella, even when a native Bun guest
// uses its own Pi API facade. None are extension allowlist entries.
// Keep aligned with cetas-js/src/app/pi-commands.ts.
var piHostDependencies = map[string]string{
 "@earendil-works/pi-tui": "^1.3.0",
 "@earendil-works/pi-coding-agent": "^1.0.4",
 "@earendil-works/pi-agent-core": "^1.0.4",
 "@earendil-works/pi-ai": "^1.0.4",
 "typebox": "^1.3.27",
}

// ensurePiUmbrella preserves user-managed package versions and other fields.
// It is called only during an explicit /pi install, never on startup.
func ensurePiUmbrella(root string) error {
 if err := os.MkdirAll(root,0700);err!=nil{return err}
 manifestPath:=filepath.Join(root,"package.json")
 raw,err:=os.ReadFile(manifestPath)
 if os.IsNotExist(err) {
  raw=[]byte(`{"name":"cetas-pi-packages","private":true,"type":"module"}`)
 } else if err!=nil{return err}
 var manifest map[string]json.RawMessage
 if err=json.Unmarshal(raw,&manifest);err!=nil{return fmt.Errorf("Pi umbrella package.json: %w",err)}
 if manifest==nil {return fmt.Errorf("Pi umbrella package.json must be an object")}
 deps:=map[string]json.RawMessage{}
 if value,ok:=manifest["dependencies"];ok {
  if err=json.Unmarshal(value,&deps);err!=nil||deps==nil{return fmt.Errorf("Pi umbrella dependencies must be an object")}
 }
 changed:=false
 for name,wanted:=range piHostDependencies {
  if _,exists:=deps[name];exists{continue}
  version,err:=json.Marshal(wanted)
  if err!=nil{return err}
  deps[name]=version
  changed=true
 }
 if !changed{return nil}
 manifest["dependencies"],err=json.Marshal(deps)
 if err!=nil{return err}
 data,err:=json.MarshalIndent(manifest,"","  ")
 if err!=nil{return err}
 return os.WriteFile(manifestPath,append(data,'\n'),0600)
}


// Windows npm/pnpm/yarn are often .cmd shims rather than PE executables.
// Match cetas-js: only route non-native shims through cmd.exe, with package
// arguments validated by piPackageName before reaching this function.
func piPackageRunner(ctx context.Context, manager, verb, pkg string) *exec.Cmd {
	lower := strings.ToLower(manager)
	if runtime.GOOS == "windows" && !strings.HasSuffix(lower, ".exe") && !strings.HasSuffix(lower, ".com") {
		command := os.Getenv("ComSpec")
		if command == "" {
			command = "cmd.exe"
		}
		return exec.CommandContext(ctx, command, "/d", "/s", "/c", manager, verb, pkg)
	}
	return exec.CommandContext(ctx, manager, verb, pkg)
}

// Bounded npm output capture: progress is based on actual subprocess activity.
// Do not display untrusted raw npm output in activities (registry URLs may
// embed tokens). Failures keep only the trailing diagnostic output.
type packageOutput struct {
	mu sync.Mutex
	buf bytes.Buffer
	total int64
	last time.Time
	progress func(int64)
}

func (w *packageOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.total += int64(len(p))
	if len(p) >= 16<<10 {
		w.buf.Reset()
		_, _ = w.buf.Write(p[len(p)-(16<<10):])
	} else {
		if w.buf.Len()+len(p) > 16<<10 {
			previous := append([]byte(nil), w.buf.Bytes()...)
			keep := (16 << 10) - len(p)
			if len(previous) > keep {
				previous = previous[len(previous)-keep:]
			}
			w.buf.Reset()
			_, _ = w.buf.Write(previous)
		}
		_, _ = w.buf.Write(p)
	}
	if w.progress != nil && time.Since(w.last) > 200*time.Millisecond {
		w.last = time.Now()
		w.progress(w.total)
	}
	return len(p), nil
}

func (w *packageOutput) Output() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.String()
}


type piSnapshot struct {
	Raw      map[string]json.RawMessage
	Packages []string
	Manager  string
}

func piHome(value string) (string, error) {
	if value != "" {
		return value, nil
	}
	if home := os.Getenv("CETAS_HOME"); home != "" {
		return home, nil
	}
	return os.UserHomeDir()
}
func readPiSnapshot(path string) (piSnapshot, error) {
	cfg := piSnapshot{Raw: map[string]json.RawMessage{}, Manager: "npm"}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if err = json.Unmarshal(raw, &cfg.Raw); err != nil {
		return cfg, fmt.Errorf("invalid pi-packages.json: %w", err)
	}
	if v, ok := cfg.Raw["packages"]; ok {
		if err = json.Unmarshal(v, &cfg.Packages); err != nil {
			return cfg, fmt.Errorf("invalid Pi packages list: %w", err)
		}
	}
	if v, ok := cfg.Raw["npmCommand"]; ok {
		var manager string
		if json.Unmarshal(v, &manager) == nil && strings.TrimSpace(manager) != "" {
			cfg.Manager = strings.TrimSpace(manager)
		}
		if manager == "" {
			var choices []string
			if json.Unmarshal(v, &choices) == nil {
				for _, item := range choices {
					if strings.TrimSpace(item) != "" {
						cfg.Manager = strings.TrimSpace(item)
						break
					}
				}
			}
		}
	}
	return cfg, nil
}
func piPackageDependencies(root string) map[string]bool {
	deps := map[string]bool{}
	data, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil {
		return deps
	}
	var p struct {
		Dependencies map[string]any `json:"dependencies"`
	}
	if json.Unmarshal(data, &p) == nil {
		for k := range p.Dependencies {
			deps[k] = true
		}
	}
	return deps
}
func writePiSnapshot(path string, config piSnapshot) error {
	next, err := json.MarshalIndent(config.Packages, "", "  ")
	if err != nil {
		return err
	}
	config.Raw["packages"] = next
	content, err := json.MarshalIndent(config.Raw, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(content, '\n'), 0600)
}
func piLines(lines ...string) (json.RawMessage, error) {
	payload, err := json.Marshal(map[string]any{"lines": lines})
	return payload, err
}
func (s *piSupervisor) packageCommand(ctx context.Context, args any) (json.RawMessage, error) {
	var req struct {
		Args string `json:"args"`
	}
	data, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	if err = json.Unmarshal(data, &req); err != nil {
		return nil, err
	}
	words := strings.Fields(req.Args)
	cmd := "list"
	if len(words) > 0 {
		cmd = words[0]
	}
	if cmd == "help" {
		return piLines("usage: /pi install <package>", "       /pi remove <package>", "       /pi list", "Manage the shared cetas-js Pi package store.")
	}
	s.mu.Lock()
	home := s.home
	s.mu.Unlock()
	home, err = piHome(home)
	if err != nil {
		return nil, err
	}

	root := filepath.Join(home, ".cetas", "pi-packages")
	configPath := filepath.Join(home, ".cetas", "pi-packages.json")
	piInstallMu.Lock()
	defer piInstallMu.Unlock()
	snapshot, err := readPiSnapshot(configPath)
	if err != nil {
		return nil, err
	}
	if cmd == "list" {
		if len(snapshot.Packages) == 0 {
			return piLines("no Pi packages configured", "Install using /pi install <package>.")
		}
		lines := []string{"Pi packages (allowlist):"}
		for _, pkg := range snapshot.Packages {
			candidates := []string{filepath.Join(root, "node_modules", pkg, "package.json"), filepath.Join(root, pkg, "package.json")}
			status := "missing"
			for _, manifest := range candidates {
				if _, err := os.Stat(manifest); err == nil {
					status = "installed"
					break
				}
			}
			lines = append(lines, fmt.Sprintf("%s  %s", status, pkg))
		}
		return piLines(lines...)
	}
	if cmd != "install" && cmd != "remove" {
		return piLines("unknown /pi subcommand: "+cmd, "Use /pi help")
	}
	if len(words) != 2 || !piPackageName.MatchString(words[1]) || strings.HasPrefix(words[1], "-") {
		return piLines("invalid package name; usage: /pi " + cmd + " <package>")
	}
	pkg := words[1]
	if cmd == "remove" {
		present := false
		for _, name := range snapshot.Packages {
			if name == pkg {
				present = true
				break
			}
		}
		if !present {
			return piLines(pkg + " is not in the Pi allowlist")
		}
		if _, err := os.Stat(root); err != nil {
			return piLines("Pi package root not found: " + root)
		}
	} else {
		if err = ensurePiUmbrella(root); err != nil {
			return nil, err
		}
	}
	before := piPackageDependencies(root)
	// Executed with argv, never a shell; package spec is a single validated arg.
	runner := piPackageRunner(ctx, snapshot.Manager, map[bool]string{true: "add", false: "remove"}[cmd == "install"], pkg)
	runner.Dir = root
	runner.Stdin = nil
	activityID := "pi:" + pkg
	activityLabel := fmt.Sprintf("Pi %s · %s", cmd, pkg)
	s.host.activity(activityID, activityLabel, "running", snapshot.Manager+" "+map[bool]string{true: "add", false: "remove"}[cmd == "install"], 0, 0)
	capture := &packageOutput{progress: func(written int64) {
		s.host.activity(activityID, activityLabel, "running", fmt.Sprintf("Package manager running · %d KiB of output", written/1024), 0, 0)
	}}
	runner.Stdout = capture
	runner.Stderr = capture
	err = runner.Run()
	output := capture.Output()
	if err != nil {
		s.host.activity(activityID, activityLabel, "failed", err.Error(), 0, 0)
		msg := strings.TrimSpace(string(output))
		if len(msg) > 1200 {
			msg = msg[len(msg)-1200:]
		}
		return piLines(fmt.Sprintf("/pi %s %s failed: %v", cmd, pkg, err), msg)
	}
	if cmd == "install" {
		s.host.activity(activityID, activityLabel, "running", "Updating package allowlist", 0, 0)
		name := pkg
		added := []string{}
		for dep := range piPackageDependencies(root) {
			if !before[dep] {
				added = append(added, dep)
			}
		}
		sort.Strings(added)
		if len(added) == 1 {
			name = added[0]
		}
		found := false
		for _, configured := range snapshot.Packages {
			if configured == name {
				found = true
				break
			}
		}
		if !found {
			snapshot.Packages = append(snapshot.Packages, name)
		}
		if err = writePiSnapshot(configPath, snapshot); err != nil {
			s.host.activity(activityID, activityLabel, "failed", err.Error(), 0, 0)
			return nil, err
		}
		s.host.activity(activityID, activityLabel, "succeeded", "Installed; restart to load", 0, 0)
		return piLines("/pi install "+pkg+": added "+name+" to allowlist", "Restart cetas-go to activate the installed extension.")
	}
	kept := make([]string, 0, len(snapshot.Packages))
	for _, name := range snapshot.Packages {
		if name != pkg {
			kept = append(kept, name)
		}
	}
	snapshot.Packages = kept
	if err = writePiSnapshot(configPath, snapshot); err != nil {
		s.host.activity(activityID, activityLabel, "failed", err.Error(), 0, 0)
		return nil, err
	}
	s.host.activity(activityID, activityLabel, "succeeded", "Removed; restart to unload", 0, 0)
	return piLines("/pi remove "+pkg+": removed from allowlist", "Restart cetas-go to release any already-loaded tools.")
}
