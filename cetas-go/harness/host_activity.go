package harness

import (
	"encoding/json"
	"time"

	"github.com/colmugx/cetas/cetas-go/internal/wire"
)

// Host activities are UI-only facts, never MoonBit Agent events or persisted
// transcript turns. Progress producers are always off the EventHub pump.
type hostActivity struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	State   string `json:"state"` // running, succeeded, failed
	Detail  string `json:"detail,omitempty"`
	Current int64  `json:"current,omitempty"`
	Total   int64  `json:"total,omitempty"`
}

func (h *Host) activity(id, label, state, detail string, current, total int64) {
	if h == nil {
		return
	}
	raw, err := json.Marshal(struct {
		Type string `json:"type"`
		hostActivity
	}{Type: "host.activity", hostActivity: hostActivity{ID: id, Label: label, State: state, Detail: detail, Current: current, Total: total}})
	if err != nil {
		return
	}
	// Close and async package operations may race. Hold the same guard used
	// by the pump's channel close; never send into a closed event channel.
	h.activityMu.RLock()
	defer h.activityMu.RUnlock()
	if h.activityClosed {
		return
	}
	select {
	case h.events <- wire.Event{Type: "host.activity", Raw: raw}:
	default:
		// Intermediate progress may be coalesced; final states retry briefly.
		if state == "running" {
			return
		}
		select {
		case h.events <- wire.Event{Type: "host.activity", Raw: raw}:
		case <-time.After(time.Second):
		}
	}
}

func (h *Host) closeActivityEvents() {
	h.activityMu.Lock()
	defer h.activityMu.Unlock()
	h.activityClosed = true
	close(h.events)
}
