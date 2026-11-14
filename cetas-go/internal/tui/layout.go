package tui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	ui "github.com/colmugx/cetas/cetas-go/internal/tui/components"
	"github.com/colmugx/cetas/cetas-go/internal/tui/overlays"
)

type regions struct {
	header, status, widgets, ask, menu, editor, dashboard []string
	transcriptHeight, editorY, transcriptY                int
}

func (m model) dimensions() (int, int) {
	w, h := m.width, m.height
	if w <= 0 {
		w = 80
	}
	if h <= 0 {
		h = 24
	}
	return w, h
}
func (m model) theme() ui.Theme { return ui.NewTheme(m.surface.fg, m.surface.bg) }

// Fixed height: a pane that grew with its result count would shift the input
// line on every keystroke.
const completionMenuRows = 6

func completionMenu(theme ui.Theme, items []string, index, width int) []string {
	if len(items) == 0 {
		return nil
	}
	start := max(0, index-5)
	end := min(len(items), start+completionMenuRows)
	rows := make([]string, 0, completionMenuRows)
	for i := start; i < end; i++ {
		line := "  " + items[i]
		if i == index {
			line = theme.Role("accent", "→ "+items[i])
		}
		rows = append(rows, ui.Pad(line, width))
	}
	// Max height, not fixed: one candidate opens a one-row hint, not six blank rows.
	return rows
}
func (m model) regions() regions {
	w, h := m.dimensions()
	theme := m.theme()
	state := ui.WelcomeState("ready")
	if m.needsSetup {
		state = "needs_setup"
	} else if m.host == nil && m.session == "" {
		state = ""
	}
	r := regions{}
	if !m.welcomeHidden {
		r.header = ui.Welcome(theme, ui.WelcomeSource{Cwd: m.surface.cwd, Home: m.surface.home, State: state, Rows: h, Version: &ui.WelcomeVersion{Version: m.version, Channel: "native"}}, w, false)
	}
	label := m.status
	if !m.running && label == "ready" {
		label = ""
	}
	if m.running {
		frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
		label = frames[m.surface.frame] + " " + label
	}
	if m.switchInFlight != "" {
		r.status = switchSkeletonLines(theme, w)
	} else if label != "" {
		r.status = []string{theme.Role("muted", " "+label)}
	}
	for _, line := range m.extensionStatusLines() {
		r.status = append(r.status, theme.Role("muted", ui.Fit(" "+line, w)))
	}
	r.status = append(r.status, m.activityLines(w, max(1, h-len(r.header)-8))...)
	r.widgets = m.widgetLines()
	if m.modalRequestID != "" {
		r.ask = ui.Ask(theme, ui.AskRequest{Kind: ui.AskKind(m.modal), Prompt: m.modalPrompt, Options: m.modalItems}, w, m.modalIndex, string(m.modalBuffer), m.surface.askExpanded)
		if len(m.pendingUI) > 0 {
			r.ask = append(r.ask, theme.Role("muted", fmt.Sprintf(" %d more question(s) queued", len(m.pendingUI))))
		}
	}
	if m.completing() {
		r.menu = completionMenu(theme, m.modalItems, m.modalIndex, w)
	}
	border := theme.Role("brand", strings.Repeat("─", w))
	r.editor = append([]string{border}, strings.Split(m.textarea.View(), "\n")...)
	r.editor = append(r.editor, border)
	r.editor = append(m.attachmentTrayLines(theme, w), r.editor...)
	entries := append([]ui.DashboardEntry(nil), m.surface.entries...)
	has := func(key string) bool {
		for _, e := range entries {
			if strings.EqualFold(e.Key, key) {
				return true
			}
		}
		return false
	}
	if !has("model") && m.surface.model != "" {
		value := m.surface.model
		if m.surface.effort != "" {
			value += ":" + m.surface.effort
		}
		entries = append(entries, ui.DashboardEntry{Key: "model", Value: value})
	}
	// The runtime snapshot owns model_slot; the statusbar's model field may
	// carry only model:effort.
	if !has("model_slot") && m.surface.model != "" {
		entries = append(entries, ui.DashboardEntry{Key: "model_slot", Value: m.surface.model})
	}
	if !has("permission") && m.surface.permission != "" {
		entries = append(entries, ui.DashboardEntry{Key: "permission", Value: m.surface.permission})
	}
	context, _ := ui.ContextOccupancy(m.surface.context)
	dashboard := ui.DashboardContext{Branch: m.surface.branch, ContextValue: context, PendingUserQuestions: len(m.surface.activities.questions)}
	for _, a := range m.surface.activities.records {
		if a.live() {
			dashboard.ActiveAgents++
			if a.questionID != "" {
				dashboard.AwaitingReplies++
			}
		}
	}
	if m.modalRequestID != "" {
		dashboard.AwaitingReplies += 1 + len(m.pendingUI)
	}
	r.dashboard = ui.Dashboard(theme, entries, w, dashboard)
	reserved := func() int {
		return len(r.header) + len(r.status) + len(r.widgets) + len(r.ask) + len(r.menu) + len(r.editor) + len(r.dashboard)
	}
	if len(r.header) > 0 && reserved() >= h {
		r.header = ui.Welcome(theme, ui.WelcomeSource{Cwd: m.surface.cwd, Home: m.surface.home, State: state, Rows: h}, w, true)
	}
	if reserved() >= h {
		r.widgets = nil
		r.menu = r.menu[:min(len(r.menu), 3)]
	}
	if reserved() >= h {
		r.header = nil
		r.status = r.status[:min(len(r.status), 1)]
	}
	if reserved() >= h {
		available := max(0, h-1-len(r.status)-len(r.editor)-len(r.dashboard)-len(r.menu))
		if available < len(r.ask) {
			if available >= 2 {
				r.ask = append(r.ask[:1], r.ask[len(r.ask)-available+1:]...)
			} else {
				r.ask = r.ask[:available]
			}
		}
	}
	if reserved() >= h {
		r.menu = nil
		// A long question shrinks its preview before the dashboard loses rows.
		available := max(0, h-1-len(r.status)-len(r.ask)-len(r.editor))
		r.dashboard = r.dashboard[:min(len(r.dashboard), available)]
		r.editor = r.editor[:min(len(r.editor), max(0, h-1-len(r.status)-len(r.ask)-len(r.dashboard)))]
	}
	r.transcriptHeight = max(1, h-reserved())
	r.transcriptY = len(r.header)
	r.editorY = len(r.header) + r.transcriptHeight + len(r.status) + len(r.widgets) + len(r.ask) + len(r.menu) + 1
	return r
}
func (m *model) reflow() {
	m.presentation.snapshot = nil
	w, h := m.dimensions()
	m.textarea.MaxHeight = max(1, min(8, h/3))
	m.textarea.SetWidth(w)
	r := m.regions()
	m.presentation.layout = &r
	themeKey := fmt.Sprintf("%v/%v", m.surface.fg, m.surface.bg)
	if m.viewport.Width() != w || m.markdownThemeKey != themeKey {
		renderer, err := newMarkdownRenderer(w, m.theme())
		if err != nil {
			m.err = "Markdown renderer initialization failed: " + err.Error()
		} else {
			m.markdownRenderer = renderer
			m.markdownCache.reset()
			m.markdownThemeKey = themeKey
			m.document.live.valid = false
		}
		m.viewport.SetWidth(w)
	}
	m.viewport.SetHeight(r.transcriptHeight)
	m.refreshTranscript()
}
func (m *model) resize() { m.reflow() }
func (m model) View() tea.View {
	if m.presentation.snapshot != nil && m.presentation.layout != nil {
		return *m.presentation.snapshot
	}
	return m.renderView()
}

func overlayPanelSize(width, height int) (int, int) {
	return min(width-2, max(4, width*88/100)), min(height-1, max(4, height*82/100))
}

func (m model) overlayTitle() string {
	title := m.modalPrompt
	if title == "" {
		title = map[string]string{"models": "Choose a model", "efforts": "Reasoning effort", "sessions": "Sessions", "providers": "Connect a provider", "login_methods": "Authentication method", "rewind": "Rewind", "skills_browse": "Skills"}[m.modal]
	}
	if title == "" {
		title = m.modal
	}
	return title
}

// Every input the picker render reads. Within one minute bucket the render is
// pure, so an unchanged key means the memoized panel is what a fresh render
// would produce.
type pickerPanelKey struct {
	open        bool
	bucket      string
	scope       overlays.SessionsScope
	generation  int
	content     uint64
	index       int
	entries     int
	loading     bool
	err         string
	more        bool
	minute      int64
	fg, bg      string
	width, tall int
}

// The wheel path hit-tests and the paint path compose the same panel, so a
// frame over the picker renders it once instead of twice.
type pickerPanelMemo struct {
	key                      pickerPanelKey
	panel                    []string
	left, top, width, height int
}

func (m model) pickerPanelKey(width, tall int, now time.Time) pickerPanelKey {
	panel := m.sessionPicker.panel
	return pickerPanelKey{
		open:       m.sessionPicker.open,
		bucket:     panel.Bucket,
		scope:      panel.Scope,
		generation: panel.Generation,
		content:    m.sessionPicker.content,
		index:      panel.Index,
		entries:    len(panel.Entries),
		loading:    panel.Loading,
		err:        panel.Err,
		more:       panel.More,
		minute:     now.Truncate(time.Minute).UnixMilli(),
		fg:         fmt.Sprintf("%v", m.surface.fg),
		bg:         fmt.Sprintf("%v", m.surface.bg),
		width:      width,
		tall:       tall,
	}
}

// Reports exactly where the panel lands so painting and pointer routing can
// never disagree: the compositor centres the panel's *measured* lines, which is
// narrower than the requested box when the content does not fill it.
func (m model) overlayPanel() (panel []string, left, top, width, height int) {
	w, h := m.dimensions()
	pw, ph := overlayPanelSize(w, h)
	if m.modal != "" {
		if m.modal == "models" {
			// Fixed pane: the list length changes every keystroke, and a box
			// that resized with it would jump and recentre.
			panel = ui.PanelFixed(m.theme(), m.overlayTitle(), m.modalItems, m.modalIndex, pw, ph, 9)
		} else {
			panel = ui.Panel(m.theme(), m.overlayTitle(), m.modalItems, m.modalIndex, pw, ph)
		}
	} else {
		now := time.Now()
		key := m.pickerPanelKey(pw, ph, now)
		if m.pickerPanel != nil && m.pickerPanel.key == key {
			memo := m.pickerPanel
			return memo.panel, memo.left, memo.top, memo.width, memo.height
		}
		panel = m.sessionPicker.panel.Render(m.theme(), pw, ph, now)
		measured := 0
		for _, line := range panel {
			measured = max(measured, ansi.StringWidth(line))
		}
		width, height = min(w, measured), min(h, len(panel))
		if m.pickerPanel == nil {
			m.pickerPanel = &pickerPanelMemo{}
		}
		m.pickerPanel.key = key
		m.pickerPanel.panel = panel
		m.pickerPanel.width, m.pickerPanel.height = width, height
		m.pickerPanel.left, m.pickerPanel.top = max(0, (w-width)/2), max(0, (h-height)/2)
		return panel, m.pickerPanel.left, m.pickerPanel.top, width, height
	}
	measured := 0
	for _, line := range panel {
		measured = max(measured, ansi.StringWidth(line))
	}
	width, height = min(w, measured), min(h, len(panel))
	return panel, max(0, (w-width)/2), max(0, (h-height)/2), width, height
}

// A UiPort ask never reaches here: it owns its own layout region.
func (m model) overlayActive() bool {
	return (m.modal != "" || m.sessionPicker.open) && m.modalRequestID == "" && !m.completing()
}

// The typed picker scrolls only while the pointer is over the panel it painted;
// a pointer outside it moves nothing, since the covered transcript must not
// scroll as a fallback.
func (m *model) wheelRoute(x, y, delta int) tea.Cmd {
	if delta == 0 {
		return nil
	}
	if m.sessionPickerFocused() {
		_, left, top, width, height := m.overlayPanel()
		if x >= left && x < left+width && y >= top && y < top+height {
			return m.sessionPickerMove(delta)
		}
		return nil
	}
	// An ask owns its own region; the transcript above stays scrollable.
	if m.modal == "" || m.modalRequestID != "" {
		m.scrollTranscript(delta)
	}
	return nil
}

func (m model) renderView() tea.View {
	w, h := m.dimensions()
	r := m.presentedRegions()
	lines := append([]string(nil), r.header...)
	history := strings.Split(m.viewport.View(), "\n")
	history = history[:min(len(history), r.transcriptHeight)]
	for len(history) < r.transcriptHeight {
		history = append(history, strings.Repeat(" ", w))
	}
	if m.virtualScroll != nil && !m.virtualScroll.followEnd && len(history) > 0 {
		history[len(history)-1] = m.theme().Role("accent", ui.Fit("↓ newer messages", w))
	}
	lines = append(lines, history...)
	lines = append(lines, r.status...)
	lines = append(lines, r.widgets...)
	lines = append(lines, r.ask...)
	lines = append(lines, r.menu...)
	lines = append(lines, r.editor...)
	lines = append(lines, r.dashboard...)
	overlay := m.overlayActive()
	if overlay {
		panel, _, _, _, _ := m.overlayPanel()
		lines = ui.ComposeOverlay(m.theme(), lines, panel, w, h)
	}
	lines = m.paintSearchPanel(lines, w, h)
	lines = ui.Bound(lines, w, h)
	view := tea.NewView(strings.Join(lines, "\n"))
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	if !overlay && m.modalRequestID == "" && !m.surface.searchOpen {
		if cursor := m.textarea.Cursor(); cursor != nil {
			copy := *cursor
			copy.Y += r.editorY
			if copy.Y < h && copy.X < w {
				view.Cursor = &copy
			}
		}
	}
	if m.modalRequestID != "" && (m.modal == "input" || m.modal == "secret") {
		start := len(r.header) + r.transcriptHeight + len(r.status) + len(r.widgets)
		for i, line := range r.ask {
			if strings.HasPrefix(ansi.Strip(line), "> ") && start+i < h {
				value := string(m.modalBuffer)
				if m.modal == "secret" {
					value = strings.Repeat("•", len(m.modalBuffer))
				}
				view.Cursor = tea.NewCursor(min(w-1, 2+ansi.StringWidth(value)), start+i)
				break
			}
		}
	}
	return view
}
