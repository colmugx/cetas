package tui

import (
	"time"

	tea "charm.land/bubbletea/v2"
)

type scheduledUITick struct {
	at         time.Time
	generation uint64
}

// Only work whose displayed value can change with time earns a wakeup; a TTL
// gets one exact deadline, never a polling loop.
func (m model) nextUIWake(now time.Time) time.Time {
	var due time.Time
	consider := func(t time.Time) {
		if !t.IsZero() && (due.IsZero() || t.Before(due)) {
			due = t
		}
	}
	consider(m.replayRetryAt)
	// Without this deadline the debounced completion request would wait for an
	// unrelated message to pump it.
	consider(m.completionDueAt)
	// A lost transcript index reply must wake even on an idle screen to retry.
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
	// An earlier pending timer will re-evaluate demand; never launch a second
	// animation chain for each incoming token.
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
