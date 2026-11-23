package harness

import (
	"encoding/json"
	"unicode/utf8"
)

// decodeCommandArgs preserves the JSON contract for alternate argument shapes
// (including custom marshalers, folded field names and marshaling errors).
func decodeCommandArgs(args, dst any) error {
	raw, err := json.Marshal(args)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, dst)
}

// directStringArg accepts a single canonical field. Extra keys must fall back:
// JSON may match a case variant or reject an otherwise ignored value.
func directStringArg(args any, key string) (string, bool) {
	switch fields := args.(type) {
	case nil:
		return "", true
	case map[string]any:
		value, ok := fields[key]
		if len(fields) == 0 || (len(fields) == 1 && ok) {
			if value == nil {
				return "", true
			}
			text, ok := value.(string)
			return text, ok && utf8.ValidString(text)
		}
	case map[string]string:
		if len(fields) == 0 {
			return "", true
		}
		if text, ok := fields[key]; len(fields) == 1 && ok {
			return text, utf8.ValidString(text)
		}
	}
	return "", false
}
