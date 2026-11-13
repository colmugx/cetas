package tui

import (
	"encoding/json"
	"fmt"
	"image/color"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	ui "github.com/colmugx/cetas/cetas-native/internal/tui/components"
)

type mountedWidget struct {
	Lines   []string
	Expires time.Time
}
type surfaceState struct {
	frame                     int
	fg, bg                    color.Color
	cwd, home, branch         string
	model, effort, permission string
	context                   ui.ContextState
	entries                   []ui.DashboardEntry
	widgets                   map[string]mountedWidget
	statuses                  map[string]mountedWidget
	entriesExpires            time.Time
	notices                   map[string]int
	noticeExpires             map[string]time.Time
	activities                activityState
	usage                     tokenUsage
	// Presentation maps are reset with the owning session, never process-global.
	askExpanded bool
	searchOpen  bool
	searchInput string
}

func initialSurface() surfaceState {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "."
	}
	home, _ := os.UserHomeDir()
	return surfaceState{cwd: cwd, home: home, branch: workspaceBranch(cwd)}
}
func workspaceBranch(cwd string) string {
	for depth := 0; depth < 20; depth++ {
		git := filepath.Join(cwd, ".git")
		if info, err := os.Stat(git); err == nil {
			if !info.IsDir() {
				data, err := os.ReadFile(git)
				if err != nil {
					return ""
				}
				path, ok := strings.CutPrefix(strings.TrimSpace(string(data)), "gitdir: ")
				if !ok {
					return ""
				}
				if !filepath.IsAbs(path) {
					path = filepath.Join(cwd, path)
				}
				git = path
			}
			data, err := os.ReadFile(filepath.Join(git, "HEAD"))
			if err != nil {
				return ""
			}
			name := strings.TrimSpace(string(data))
			if branch, ok := strings.CutPrefix(name, "ref: refs/heads/"); ok {
				return ui.Clean(branch)
			}
			return ""
		}
		parent := filepath.Dir(cwd)
		if parent == cwd {
			break
		}
		cwd = parent
	}
	return ""
}
func (m *model) snapshotSurface(raw json.RawMessage) {
	var s struct {
		Model      *string `json:"model"`
		Effort     *string `json:"effort"`
		Permission *string `json:"permission"`
		Cwd        *string `json:"cwd"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		m.err = "invalid runtime snapshot: " + err.Error()
		return
	}
	if s.Model != nil {
		m.surface.model = *s.Model
	}
	if s.Effort != nil {
		m.surface.effort = *s.Effort
	}
	if s.Permission != nil {
		m.surface.permission = *s.Permission
	}
	if s.Cwd != nil && *s.Cwd != m.surface.cwd {
		m.surface.cwd = *s.Cwd
		m.surface.branch = workspaceBranch(*s.Cwd)
	}
}
func (m *model) surfaceEvent(kind string, raw json.RawMessage) bool {
	switch kind {
	case "session.snapshot":
		m.snapshotSurface(raw)
	case "infra.ready":
		var s struct {
			Snapshot json.RawMessage `json:"snapshot"`
		}
		if json.Unmarshal(raw, &s) == nil {
			m.snapshotSurface(s.Snapshot)
		}
	case "context.state":
		var s struct {
			ui.ContextState
			Measured *int64 `json:"measured_tokens"`
		}
		if err := json.Unmarshal(raw, &s); err != nil {
			m.err = "invalid context state: " + err.Error()
			return true
		}
		if s.Source == "" {
			s.Source = "unknown"
			if s.Measured != nil {
				zero := int64(0)
				s.Source = "measured"
				s.LastMeasuredTokens = s.Measured
				s.EstimatedAddedTokens = &zero
			}
		}
		m.surface.context = s.ContextState
		return true
	case "compact.started":
		m.status = "compacting"
		return true
	case "compact.finished":
		m.status = "ready"
		return true
	case "stream.dropped":
		m.err = "Some streamed content was dropped by the runtime; history may contain the complete result."
		return true
	case "ui.response_error":
		var r struct{ Kind, Reason string }
		if json.Unmarshal(raw, &r) == nil {
			m.err = "UI response rejected (" + r.Kind + "): " + r.Reason
		}
		return true
	case "mcp.login":
		// The MCP OAuth flow's device-code/URL notice. The flow polls on its
		// own; this line is what tells the user where to authorize.
		var r struct {
			VerificationURI string `json:"verification_uri"`
			UserCode        string `json:"user_code"`
			Hint            string `json:"hint"`
			URL             string `json:"url"`
			Message         string `json:"message"`
		}
		if json.Unmarshal(raw, &r) == nil {
			switch {
			case r.VerificationURI != "" && r.UserCode != "":
				m.protocolNotice("MCP login: open " + r.VerificationURI + " and enter code " + r.UserCode)
			case r.URL != "":
				m.protocolNotice("MCP login: open " + r.URL)
			case r.Message != "":
				m.protocolNotice("MCP login: " + r.Message)
			}
		}
		return true
	case "config.warning":
		var r struct{ Field, Reason string }
		if json.Unmarshal(raw, &r) == nil {
			m.protocolNotice("Configuration warning: " + r.Field + " · " + r.Reason)
		}
		return true
	case "config.changed":
		var r struct{ Field string }
		if json.Unmarshal(raw, &r) == nil {
			m.status = r.Field + " changed"
		}
		return true
	case "operation.finalized":
		var r struct{ Operation, Outcome, Detail string }
		if json.Unmarshal(raw, &r) == nil {
			m.protocolNotice(r.Operation + ": " + r.Outcome + " · " + r.Detail)
		}
		return true
	case "ui.render":
		var envelope struct {
			Render json.RawMessage `json:"render"`
		}
		if err := json.Unmarshal(raw, &envelope); err != nil {
			m.err = "invalid UI render envelope: " + err.Error()
			return true
		}
		if len(envelope.Render) > 0 && string(envelope.Render) != "null" {
			raw = envelope.Render
		}
		var r struct {
			Slot    string              `json:"slot"`
			Key     string              `json:"key"`
			Title   string              `json:"title"`
			Text    string              `json:"text"`
			Lines   []string            `json:"lines"`
			Entries []ui.DashboardEntry `json:"entries"`
			TTL     int                 `json:"ttl_ms"`
			Body    json.RawMessage     `json:"body"`
		}
		if err := json.Unmarshal(raw, &r); err != nil {
			m.err = "invalid UI render: " + err.Error()
			return true
		}
		var body struct {
			Type    string              `json:"type"`
			Text    string              `json:"text"`
			Lines   []string            `json:"lines"`
			Entries []ui.DashboardEntry `json:"entries"`
			Current float64             `json:"current"`
			Label   string              `json:"label"`
		}
		if len(r.Body) > 0 && string(r.Body) != "null" {
			if err := json.Unmarshal(r.Body, &body); err != nil {
				m.err = "invalid UI body: " + err.Error()
				return true
			}
			switch body.Type {
			case "text", "markdown":
				r.Text = body.Text
			case "lines":
				r.Lines = body.Lines
			case "entries", "key_value":
				r.Entries = body.Entries
			case "progress":
				if body.Current < 0 || body.Current > 1 {
					m.err = "invalid UI progress: current must be within [0, 1]"
					return true
				}
				label := r.Title
				if label == "" {
					label = r.Key
				}
				parts := []string{}
				for _, value := range []string{label, body.Label, fmt.Sprintf("%.0f%%", body.Current*100)} {
					if value != "" {
						parts = append(parts, value)
					}
				}
				r.Text = strings.Join(parts, " · ")
				r.Title = ""
			default:
				m.err = "unsupported UI body: " + body.Type
				return true
			}
		}
		slot := strings.ToLower(r.Slot)
		key := r.Key
		if key == "" {
			key = slot
		}
		expires := time.Time{}
		if r.TTL > 0 {
			expires = time.Now().Add(time.Duration(r.TTL) * time.Millisecond)
		}
		if strings.Contains(slot, "status") && strings.Contains(strings.ToLower(key), "statusbar") {
			m.surface.entries = append([]ui.DashboardEntry(nil), r.Entries...)
			m.surface.entriesExpires = expires
			return true
		}
		lines := r.Lines
		if len(lines) == 0 && r.Text != "" {
			lines = strings.Split(r.Text, "\n")
		}
		if len(r.Entries) > 0 {
			for _, e := range r.Entries {
				lines = append(lines, e.Key+" "+e.Value)
			}
		}
		if r.Title != "" {
			lines = append([]string{r.Title}, lines...)
		}
		if strings.Contains(slot, "widget") {
			if m.surface.widgets == nil {
				m.surface.widgets = map[string]mountedWidget{}
			}
			w := mountedWidget{Lines: lines, Expires: expires}
			if len(lines) == 0 {
				delete(m.surface.widgets, key)
			} else {
				m.surface.widgets[key] = w
			}
			return true
		}
		if strings.Contains(slot, "status") {
			if len(envelope.Render) == 0 || string(envelope.Render) == "null" {
				// The old flat bridge encoded a single status string.
				m.status = strings.Join(lines, " · ")
			} else {
				if m.surface.statuses == nil {
					m.surface.statuses = map[string]mountedWidget{}
				}
				if len(lines) == 0 {
					delete(m.surface.statuses, key)
				} else {
					m.surface.statuses[key] = mountedWidget{Lines: lines, Expires: expires}
				}
			}
			return true
		}
		if strings.Contains(slot, "notice") {
			if m.surface.noticeExpires == nil {
				m.surface.noticeExpires = map[string]time.Time{}
			}
			m.surface.noticeExpires[key] = expires
			if len(lines) == 0 {
				if at, ok := m.surface.notices[key]; ok {
					m.removeNoticeBlock(at)
				}
				return true
			}
			if m.surface.notices == nil {
				m.surface.notices = map[string]int{}
			}
			// Extension notice lines are runtime text painted through the raw
			// transcript path: same SGR allowlist as tool results.
			for i := range lines {
				lines[i] = ui.SanitizeSGR(lines[i])
			}
			if at, ok := m.surface.notices[key]; ok && at < len(m.transcript) {
				m.transcript[at] = strings.Join(lines, "\n")
				m.invalidateTranscriptBlock(at)
			} else {
				m.surface.notices[key] = len(m.transcript)
				m.transcript = append(m.transcript, strings.Join(lines, "\n"))
			}
			return true
		}
		m.err = "unsupported UI slot: " + r.Slot
		return true
	}
	return false
}
func (m model) widgetLines() []string {
	keys := []string{}
	for key := range m.surface.widgets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	lines := []string{}
	for _, key := range keys {
		lines = append(lines, m.surface.widgets[key].Lines...)
	}
	return lines
}

// Retire only the departed session's presentation, explicitly cancelling its
// abandoned asks instead of carrying an approval into another conversation.
func (m *model) retireSessionPresentation() tea.Cmd {
	ids := []string{}
	if m.modalRequestID != "" {
		ids = append(ids, m.modalRequestID)
	}
	for _, p := range m.pendingUI {
		ids = append(ids, p.id)
	}
	cmds := []tea.Cmd{}
	if m.host != nil {
		for _, id := range ids {
			cmds = append(cmds, request(m.host, "ui_response", map[string]any{"request_id": id, "cancelled": true}))
		}
	}
	m.pendingUI = nil
	m.deferredDialogs = nil
	m.modalRequestID = ""
	m.modal = ""
	m.modalPrompt = ""
	m.clearModalBuffer()
	m.modalItems = nil
	m.modalValues = nil
	m.fragments = nil
	m.blocks = nil
	old := m.surface
	m.surface = surfaceState{fg: old.fg, bg: old.bg, cwd: old.cwd, home: old.home, branch: old.branch}
	return tea.Batch(cmds...)
}
