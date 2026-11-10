package tui

import (
	tea "charm.land/bubbletea/v2"
	"time"
)

type scheduledUITick struct {
	at         time.Time
	generation uint64
}

// Only work whose displayed value can change with time earns a wakeup. TTLs
// get one exact deadline; they do not keep a polling animation alive.
func (m model) nextUIWake(now time.Time) time.Time {
	var due time.Time
	consider := func(t time.Time) {
		if !t.IsZero() && (due.IsZero() || t.Before(due)) {
			due = t
		}
	}
	consider(m.replayRetryAt)
	// A lost cold transcript index reply must wake even on an idle screen;
	// the timeout handler releases the latch and retries with a fresh deadline.
	if m.replayIndexPending && !m.replayIndexSince.IsZero() {
		consider(m.replayIndexSince.Add(replayIndexTimeout + time.Millisecond))
	}
	if m.running {
		consider(now.Add(80 * time.Millisecond))
	}
	if m.markdownRenderPending() || m.historyMarkdownPending() {
		consider(now.Add(50 * time.Millisecond))
	}
	for _, a := range m.surface.activities.records {
		if a.live() {
			consider(now.Add(time.Second))
			break
		}
	}
	for _, renders := range []map[string]mountedWidget{m.surface.statuses, m.surface.widgets} {
		for _, r := range renders {
			consider(r.Expires)
		}
	}
	consider(m.surface.entriesExpires)
	for _, expiry := range m.surface.noticeExpires {
		consider(expiry)
	}
	for _, q := range m.surface.activities.questions {
		if q.Deadline > 0 {
			consider(time.UnixMilli(q.Deadline).Add(time.Millisecond))
		}
	}
	bar := m.document.scrollbar
	if !bar.dragging && !bar.hover && bar.hideAt.After(now) {
		consider(bar.hideAt)
	}
	return due
}
func (m *model) scheduleUIClock(now time.Time) tea.Cmd {
	due := m.nextUIWake(now)
	if due.IsZero() {
		if !m.clockDue.IsZero() {
			m.clockGeneration++
			m.clockDue = time.Time{}
		}
		return nil
	}
	// A pending earlier timer also services this deadline, and will re-evaluate
	// demand. Never launch a second animation chain for each incoming token.
	if !m.clockDue.IsZero() && !due.Before(m.clockDue) {
		return nil
	}
	m.clockGeneration++
	generation := m.clockGeneration
	m.clockDue = due
	delay := due.Sub(now)
	if delay < 0 {
		delay = 0
	}
	return tea.Tick(delay, func(at time.Time) tea.Msg { return scheduledUITick{at: at, generation: generation} })
}
