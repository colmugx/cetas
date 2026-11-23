package nativepi

import (
	"bufio"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

//go:embed bun_guest.mjs
var bunWorkerScript []byte

//go:embed pi_host_compat.mjs
var piHostCompatScript []byte

// RuntimeGuest is the kernel-facing contract for a supervised Pi subprocess.
type RuntimeGuest interface {
	Catalog() ([]Tool, uint64)
	Emit([]byte) error
	Execute(string, string, json.RawMessage) Result
	Diagnostics() []string
	Close()
}

// Command is a Pi-registered host command, kept separate from Posoco tools.
// Only descriptors, never JavaScript closures, cross the Bun/Go boundary.
type Command struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Category    string `json:"category"`
	CType       string `json:"ctype"`
	Params      []any  `json:"params"`
	Aliases     []string `json:"aliases"`
	Visible     bool   `json:"visible"`
	Shortcut    string `json:"shortcut,omitempty"`
}

type CommandOutcome struct {
	Type     string `json:"type"`
	Feedback string `json:"feedback,omitempty"`
	Reason   string `json:"reason,omitempty"`
}
type PiCustomEntry struct {
	ID         string          `json:"id"`
	CustomType string          `json:"customType"`
	Data       json.RawMessage `json:"data"`
}

type PiOutgoingMessage struct {
	ID          string `json:"id"`
	Text        string `json:"text"`
	TriggerTurn bool   `json:"triggerTurn"`
	DeliverAs   string `json:"deliverAs"`
	Display     bool   `json:"display"`
}

type PiOutbox struct {
	Entries  []PiCustomEntry
	Messages []PiOutgoingMessage
}

// Commander exposes Pi slash commands, separate from the tool catalog.
type Commander interface {
	Commands() ([]Command, uint64)
	RunCommand(name, args string) CommandOutcome
}

type bunReply struct {
	ID         uint64   `json:"id"`
	Kind       string   `json:"kind"`
	Tools      []Tool   `json:"tools"`
	Generation uint64   `json:"generation"`
	Commands []Command `json:"commands"`
	CommandGeneration uint64 `json:"commandGeneration"`
	Outcome CommandOutcome `json:"outcome"`
	Entries []PiCustomEntry `json:"entries"`
	Messages []PiOutgoingMessage `json:"messages"`
	Warnings   []string `json:"warnings"`
	Result     Result   `json:"result"`
	Error      string   `json:"error"`
}
type BunGuest struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	input      io.WriteCloser
	output     *bufio.Scanner
	done       chan error
	script     string
	cwd        string
	next       uint64
	catalog    []Tool
	generation uint64
	commands []Command
	commandGeneration uint64
	warnings   []string
	events     EventBridge
	closeOnce  sync.Once
}

// The Bun subprocess must not inherit provider tokens, SDK keys or Cetas
// authentication variables from the native host's environment. These
// platform runtime variables enable core Node/Bun functionality only.
// Further extension capabilities require an explicit permission design.
func bunGuestEnv(home string) []string {
	keys := []string{"PATH", "SYSTEMROOT", "WINDIR", "HOME", "USERPROFILE",
		"HOMEDRIVE", "HOMEPATH", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "TERM"}
	env := make([]string, 0, len(keys)+1)
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return append(env, "CETAS_HOME="+home, "PI_CODING_AGENT_DIR="+filepath.Join(home, ".cetas"))
}

// OpenBun never downloads a runtime. The caller must explicitly prepare
// a checked binary and opt into using it before starting this subprocess.
func OpenBun(binary, home, cwd string) (*BunGuest, error) {
	if !filepath.IsAbs(binary) {
		return nil, errors.New("Bun binary path must be absolute")
	}
	if stat, err := os.Stat(binary); err != nil || !stat.Mode().IsRegular() {
		return nil, fmt.Errorf("Bun binary unavailable at %s: %v", binary, err)
	}
	file, err := os.CreateTemp("", "cetas-pi-bun-*.mjs")
	if err != nil {
		return nil, err
	}
	script := file.Name()
	if _, err = file.Write(append(append([]byte(nil), piHostCompatScript...), bunWorkerScript...)); err != nil {
		file.Close()
		os.Remove(script)
		return nil, err
	}
	if err = file.Close(); err != nil {
		os.Remove(script)
		return nil, err
	}
	cmd := exec.Command(binary, script, home, cwd)
	cmd.Dir = cwd
	cmd.Env = bunGuestEnv(home)
	// Extension libraries expect platform stderr logging; stdout is RPC only.
	cmd.Stderr = os.Stderr
	input, err := cmd.StdinPipe()
	if err != nil {
		os.Remove(script)
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		os.Remove(script)
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		input.Close()
		os.Remove(script)
		return nil, err
	}
	g := &BunGuest{cmd: cmd, input: input, output: bufio.NewScanner(output), done: make(chan error, 1), script: script, cwd: cwd}
	g.output.Buffer(make([]byte, 64*1024), 16<<20)
	// Do not call Cmd.Wait concurrently with StdoutPipe reads: Wait can
	// close the pipe before the final JSONL reply has been consumed.
	var reply bunReply
	if err = g.read(&reply, 30*time.Second); err != nil {
		g.Close()
		return nil, fmt.Errorf("Bun guest startup failed: %w", err)
	}
	if reply.Kind != "ready" {
		g.Close()
		return nil, fmt.Errorf("Bun guest missing ready response: %q", reply.Kind)
	}
	g.accept(reply)
	return g, nil
}
func (g *BunGuest) read(out *bunReply, timeout time.Duration) error {
	watchdog := time.AfterFunc(timeout, func() { _ = g.cmd.Process.Kill() })
	defer watchdog.Stop()
	if !g.output.Scan() {
		if err := g.output.Err(); err != nil {
			return err
		}
		return errors.New("Bun guest stopped without a response")
	}
	if err := json.Unmarshal(g.output.Bytes(), out); err != nil {
		return fmt.Errorf("Bun JSONL protocol: %w", err)
	}
	if out.Error != "" {
		return fmt.Errorf("Bun guest: %s", out.Error)
	}
	return nil
}
func (g *BunGuest) accept(reply bunReply) {
	g.catalog = append([]Tool(nil), reply.Tools...)
	g.generation = reply.Generation
	g.commands = append([]Command(nil), reply.Commands...)
	g.commandGeneration = reply.CommandGeneration
	g.warnings = append(g.warnings, reply.Warnings...)
}
func (g *BunGuest) request(kind string, data map[string]any) (bunReply, error) {
	g.next++
	data["id"] = g.next
	data["kind"] = kind
	line, err := json.Marshal(data)
	if err != nil {
		return bunReply{}, err
	}
	if _, err = g.input.Write(append(line, '\n')); err != nil {
		return bunReply{}, err
	}
	var reply bunReply
	if err = g.read(&reply, 60*time.Second); err != nil {
		return reply, err
	}
	if reply.ID != g.next {
		return reply, fmt.Errorf("Bun guest reply id %d, expected %d", reply.ID, g.next)
	}
	g.accept(reply)
	return reply, nil
}
func (g *BunGuest) Diagnostics() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.warnings...)
}
func (g *BunGuest) Catalog() ([]Tool, uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]Tool(nil), g.catalog...), g.generation
}
func (g *BunGuest) Commands() ([]Command, uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]Command(nil), g.commands...), g.commandGeneration
}

// UpdateModels projects the native session's public model picker metadata
// into the Bun extension context. Provider secrets never cross this RPC.
func (g *BunGuest) UpdateModels(snapshot json.RawMessage) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !json.Valid(snapshot) {
		return errors.New("invalid Pi model snapshot")
	}
	_, err := g.request("models", map[string]any{"snapshot": json.RawMessage(snapshot)})
	return err
}

// UpdateSession restores the owning Posoco journal's Pi custom entries.
// A Bun guest never chooses another session or opens the native store.
func (g *BunGuest) UpdateSession(snapshot json.RawMessage) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !json.Valid(snapshot) {
		return errors.New("invalid Pi session snapshot")
	}
	_, err := g.request("session", map[string]any{"snapshot": snapshot})
	return err
}

// PendingOutbox is a non-destructive snapshot. Acknowledgements happen only
// after the native host has accepted the journal write or message delivery.
func (g *BunGuest) PendingOutbox() (PiOutbox, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	reply, err := g.request("peek-outbox", map[string]any{})
	if err != nil {
		return PiOutbox{}, err
	}
	return PiOutbox{Entries:reply.Entries, Messages:reply.Messages}, nil
}

func (g *BunGuest) AckOutbox(entryIDs, messageIDs []string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	_, err := g.request("ack-outbox", map[string]any{
		"entryIds":entryIDs, "messageIds":messageIDs,
	})
	return err
}

func (g *BunGuest) RunCommand(name, args string) CommandOutcome {
	g.mu.Lock()
	defer g.mu.Unlock()
	reply, err := g.request("command", map[string]any{"name": name, "args": args})
	if err != nil {
		return CommandOutcome{Type: "failure", Reason: err.Error()}
	}
	return reply.Outcome
}

func (g *BunGuest) Emit(raw []byte) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	events, err := g.events.Translate(raw)
	if err != nil {
		return err
	}
	if len(events) == 0 {
		return nil
	}
	_, err = g.request("event", map[string]any{"events": events})
	return err
}
func (g *BunGuest) Execute(name, callID string, arguments json.RawMessage) Result {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(arguments) == 0 {
		arguments = json.RawMessage("{}")
	}
	reply, err := g.request("execute", map[string]any{"name": name, "callId": callID, "arguments": arguments})
	if err != nil {
		return Result{Content: err.Error()}
	}
	return reply.Result
}
func (g *BunGuest) Close() {
	g.closeOnce.Do(func() {
		_ = g.input.Close()
		if g.cmd.Process != nil {
			_ = g.cmd.Process.Kill()
		}
		go func() { g.done <- g.cmd.Wait() }()
		select {
		case <-g.done:
		case <-time.After(3 * time.Second):
		}
		_ = os.Remove(g.script)
	})
}

// Keep compiler checks for the guest contract in the package that owns it.
var _ RuntimeGuest = (*BunGuest)(nil)
var _ Commander = (*BunGuest)(nil)
