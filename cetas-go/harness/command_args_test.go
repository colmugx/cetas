package harness

import (
	"encoding/json"
	"fmt"
	"testing"
)

type customCommandArgs struct{}

func (customCommandArgs) MarshalJSON() ([]byte, error) {
	return []byte(`{"ACTION":"status","ARGS":"help","ID":"pi:test","arguments":{"_POSITIONAL":"custom"}}`), nil
}

func checkCommandArgs[T comparable](t *testing.T, read func(any) (T, error), args any) {
	t.Helper()
	var want T
	raw, wantErr := json.Marshal(args)
	if wantErr == nil {
		wantErr = json.Unmarshal(raw, &want)
	}
	got, err := read(args)
	if got != want || fmt.Sprint(err) != fmt.Sprint(wantErr) {
		t.Errorf("%T %#v: got %+v (%v), want %+v (%v)", args, args, got, err, want, wantErr)
	}
}

func TestCommandArgsPreserveJSONContract(t *testing.T) {
	for _, args := range []any{
		nil,
		map[string]any(nil),
		map[string]any{"action": "status"},
		map[string]any{"args": "help"},
		map[string]string{"args": "list"},
		map[string]any{"action": nil},
		map[string]any{"id": "pi:test", "session_id": "s", "request_id": "r", "arguments": map[string]any{"_positional": "some words"}},
		map[string]any{"id": "plan", "arguments": map[string]any{"count": 3}},
		map[string]any{"action": "first", "ACTION": "last", "id": "pi:two", "ID": "pi:one"},
		map[string]any{"arguments": map[string]any{"_positional": nil}},
		map[string]any{"arguments": map[string]any{"_positional": true}},
		map[string]any{"arguments": []string{"not an object"}},
		map[string]any{"action": 1, "args": false, "id": 2},
		map[string]any{"id": "ordinary", "ignored": make(chan int)},
		map[string]any{"args": "\xff"},
		map[string]any{"id": "\xff"},
		json.RawMessage(`{"Action":"status","args":"help","id":"pi:raw","arguments":null}`),
		json.RawMessage(`{"id":`),
		customCommandArgs{},
		experimentalRequest{Action: "status"},
		piPackageRequest{Args: "help"},
		piInvokeRequest{ID: "pi:typed"},
	} {
		checkCommandArgs(t, readExperimentalRequest, args)
		checkCommandArgs(t, readPiPackageRequest, args)
		checkCommandArgs(t, readPiInvokeRequest, args)
	}
}
