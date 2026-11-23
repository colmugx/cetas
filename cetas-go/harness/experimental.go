package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"unicode/utf8"
)

// Experimental features are a separate native capability surface. Managing
// Pi packages never installs or enables a JavaScript runtime.
type experimentalReply struct {
	Installed bool     `json:"installed"`
	Enabled   bool     `json:"enabled"`
	Version   string   `json:"version"`
	Lines     []string `json:"lines,omitempty"`
}

type experimentalRequest struct {
	Action string `json:"action"`
}

func readExperimentalRequest(args any) (req experimentalRequest, err error) {
	if typed, ok := args.(experimentalRequest); ok && utf8.ValidString(typed.Action) {
		return typed, nil
	}
	if action, ok := directStringArg(args, "action"); ok {
		return experimentalRequest{Action: action}, nil
	}
	err = decodeCommandArgs(args, &req)
	return req, err
}

func (s *piSupervisor) experimentalCommand(ctx context.Context, args any) (json.RawMessage, error) {
	req, err := readExperimentalRequest(args)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	home := s.home
	s.mu.Unlock()
	home, err = piHome(home)
	if err != nil {
		return nil, err
	}
	response := experimentalReply{Version: experimentalBunVersion}
	switch req.Action {
	case "", "status":
	case "prepare":
		s.host.activity("runtime:bun", "Bun Runtime", "running", "Preparing download", 0, 0)
		path, err := prepareBunWithProgress(ctx, home, func(phase string, current, total int64) {
			s.host.activity("runtime:bun", "Bun Runtime", "running", phase, current, total)
		})
		if err != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", err.Error(), 0, 0)
			return nil, fmt.Errorf("install Bun Runtime: %w", err)
		}
		s.host.activity("runtime:bun", "Bun Runtime", "running", "Checking executable version", 0, 0)
		if err = verifyBunBinary(ctx, path); err != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", err.Error(), 0, 0)
			return nil, err
		}
		s.host.activity("runtime:bun", "Bun Runtime", "succeeded", "Installed "+experimentalBunVersion, 0, 0)
		response.Lines = []string{"Bun Runtime " + experimentalBunVersion + " installed.", "Open /experimental again to enable it."}
	case "enable":
		s.host.activity("runtime:bun", "Bun Runtime", "running", "Verifying installed Bun", 0, 0)
		path, installed, e := bunPrepared(home)
		if e != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", e.Error(), 0, 0)
			return nil, e
		}
		if !installed {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", "Not installed", 0, 0)
			return nil, fmt.Errorf("Bun Runtime not installed; choose Install in /experimental first")
		}
		if err = verifyBunBinary(ctx, path); err != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", err.Error(), 0, 0)
			return nil, err
		}
		if err = setBunGuestEnabled(home, true); err != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", err.Error(), 0, 0)
			return nil, err
		}
		s.host.activity("runtime:bun", "Bun Runtime", "succeeded", "Enabled; restart required", 0, 0)
		response.Lines = []string{"Bun Runtime enabled for new sessions.", "Restart Cetas to replace an existing Pi guest."}
	case "disable":
		s.host.activity("runtime:bun", "Bun Runtime", "running", "Disabling", 0, 0)
		if err = setBunGuestEnabled(home, false); err != nil {
			s.host.activity("runtime:bun", "Bun Runtime", "failed", err.Error(), 0, 0)
			return nil, err
		}
		s.host.activity("runtime:bun", "Bun Runtime", "succeeded", "Disabled; restart required", 0, 0)
		response.Lines = []string{"Bun Runtime disabled for new sessions.", "Restart Cetas to replace an existing Pi guest."}
	default:
		return nil, fmt.Errorf("unknown experimental action %q", req.Action)
	}
	_, response.Installed, err = bunPrepared(home)
	if err != nil {
		return nil, err
	}
	response.Enabled, err = bunGuestEnabled(home)
	if err != nil {
		return nil, err
	}
	return json.Marshal(response)
}
