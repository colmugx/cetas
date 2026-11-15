package harness

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestExperimentalRuntimeOffByDefault(t *testing.T) {
	home := t.TempDir()
	enabled, err := bunGuestEnabled(home)
	if err != nil || enabled {
		t.Fatalf("Bun should be off by default: %v %v", enabled, err)
	}
	if _, err = os.Stat(experimentalSettingsPath(home)); !os.IsNotExist(err) {
		t.Fatalf("read wrote settings: %v", err)
	}
	if err = setBunGuestEnabled(home, true); err != nil {
		t.Fatal(err)
	}
	enabled, err = bunGuestEnabled(home)
	if err != nil || !enabled {
		t.Fatalf("Bun should be selected: %v %v", enabled, err)
	}
	if err = setBunGuestEnabled(home, false); err != nil {
		t.Fatal(err)
	}
	enabled, err = bunGuestEnabled(home)
	if err != nil || enabled {
		t.Fatalf("Bun should be disabled: %v %v", enabled, err)
	}
}

func TestExperimentalStatusNeverDownloads(t *testing.T) {
	home := t.TempDir()
	supervisor := &piSupervisor{home: home}
	out, err := supervisor.experimentalCommand(context.Background(), map[string]any{"action": "status"})
	if err != nil {
		t.Fatal(err)
	}
	var state experimentalReply
	if err = json.Unmarshal(out, &state); err != nil {
		t.Fatal(err)
	}
	if state.Installed || state.Enabled {
		t.Fatalf("unexpected state: %+v", state)
	}
	if _, err = os.Stat(filepath.Join(home, ".cetas", "runtimes")); !os.IsNotExist(err) {
		t.Fatalf("status downloaded a runtime: %v", err)
	}
	if _, err = supervisor.experimentalCommand(context.Background(), map[string]any{"action": "enable"}); err == nil {
		t.Fatal("enabled without explicit installation")
	}
}

func TestPiRuntimeSubcommandsAreNotExposed(t *testing.T) {
	home := t.TempDir()
	supervisor := &piSupervisor{home: home}
	answer, err := supervisor.packageCommand(context.Background(), map[string]any{"args": "runtime prepare"})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		Lines []string `json:"lines"`
	}
	if err = json.Unmarshal(answer, &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Lines) == 0 || reply.Lines[0] != "unknown /pi subcommand: runtime" {
		t.Fatalf("runtime leaked into /pi: %#v", reply.Lines)
	}
}
