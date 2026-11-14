package tui

import tea "charm.land/bubbletea/v2"

// A reducer may request several refreshes (for example a scroll followed by
// reflow). During Update these requests are deferred to the final layout pass.
// Direct document methods remain synchronous for embedded hosts and tests.
type presentationFrame struct {
	deferMount bool
	mounts     uint64
	layout     *regions
	// One immutable full View, not an LRU of historical frames. Update commits
	// it after visible state settles; direct document operations invalidate it.
	snapshot *tea.View
}

func (m *model) beginTranscriptMount() bool {
	if m.presentation.deferMount {
		return false
	}
	m.presentation.mounts++
	return true
}

func (m model) presentedRegions() regions {
	if m.presentation.layout != nil {
		return *m.presentation.layout
	}
	return m.regions()
}
