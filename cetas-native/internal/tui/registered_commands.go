package tui

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
)

type registeredCommandParam struct {
	Name       string          `json:"name"`
	PType      string          `json:"ptype"`
	Required   bool            `json:"required"`
	Positional bool            `json:"positional"`
	Choices    []string        `json:"choices"`
	Default    json.RawMessage `json:"default"`
}
type registeredCommand struct {
	ID          string                   `json:"id"`
	Label       string                   `json:"label"`
	Description string                   `json:"description"`
	Category    string                   `json:"category"`
	CType       string                   `json:"ctype"`
	Params      []registeredCommandParam `json:"params"`
	Aliases     []string                 `json:"aliases"`
	Visible     bool                     `json:"visible"`
}
type commandCatalog struct {
	SessionID string              `json:"session_id"`
	Commands  []registeredCommand `json:"commands"`
}

func (m *model) installCommandCatalog(raw json.RawMessage) {
	var data commandCatalog
	if json.Unmarshal(raw, &data) != nil || data.SessionID != m.session || data.SessionID == "" {
		return
	}
	registry := make(map[string]registeredCommand)
	for _, command := range data.Commands {
		if command.ID == "" {
			continue
		}
		id := strings.ToLower(command.ID)
		if _, ok := registry[id]; !ok {
			registry[id] = command
		}
	}
	m.dynamicCommands = registry
	m.commandSession = data.SessionID
}
func (m *model) lookupCommand(name string) (registeredCommand, bool) {
	if m.commandSession != m.session {
		return registeredCommand{}, false
	}
	key := strings.TrimPrefix(strings.ToLower(name), "/")
	if result, ok := m.dynamicCommands[key]; ok {
		return result, true
	}
	for _, result := range m.dynamicCommands {
		for _, alternate := range result.Aliases {
			if strings.EqualFold(alternate, key) {
				return result, true
			}
		}
	}
	return registeredCommand{}, false
}
func (m *model) commandSuggestions(value string) []slashSuggestion {
	suggestions := slashSuggestions(value)
	if m.commandSession != m.session || !strings.HasPrefix(value, "/") || strings.ContainsAny(value, "\n\r\t") {
		return suggestions
	}
	if strings.Contains(value, " ") {
		fields := strings.Fields(value)
		if len(fields) == 0 || len(fields) > 2 {
			return suggestions
		}
		command, ok := m.lookupCommand(fields[0])
		if !ok || len(command.Params) == 0 || len(command.Params[0].Choices) == 0 {
			return suggestions
		}
		prefix := ""
		if len(fields) == 2 && !strings.HasSuffix(value, " ") {
			prefix = strings.ToLower(fields[1])
		}
		var choices []slashSuggestion
		for _, choice := range command.Params[0].Choices {
			if strings.HasPrefix(strings.ToLower(choice), prefix) {
				choices = append(choices, slashSuggestion{label: choice, insert: "/" + command.ID + " " + choice})
			}
		}
		return choices
	}
	seen := map[string]bool{}
	for _, entry := range suggestions {
		seen[entry.insert] = true
	}
	keys := make([]string, 0, len(m.dynamicCommands))
	for key := range m.dynamicCommands {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	prefix := strings.ToLower(value)
	for _, key := range keys {
		command := m.dynamicCommands[key]
		if !command.Visible {
			continue
		}
		for _, name := range append([]string{command.ID}, command.Aliases...) {
			candidate := "/" + name
			if seen[candidate] {
				continue
			}
			low := strings.ToLower(candidate)
			if !strings.HasPrefix(low, prefix) && !slashSubsequence(low, prefix) {
				continue
			}
			description := command.Description
			if description == "" {
				description = command.Label
			}
			suggestions = append(suggestions, slashSuggestion{label: candidate + " — " + description, insert: candidate})
			seen[candidate] = true
		}
	}
	// Rank exact prefixes ahead of fuzzy subsequences across both the native
	// and composed registries, not as two unrelated suggestion lists.
	sort.SliceStable(suggestions, func(i, j int) bool {
		a := strings.HasPrefix(strings.ToLower(suggestions[i].insert), prefix)
		b := strings.HasPrefix(strings.ToLower(suggestions[j].insert), prefix)
		return a && !b
	})
	return suggestions
}
func (m *model) commandInsertion(value string) string {
	for _, local := range nativeSlashCommands {
		if local.name == value {
			return slashInsertion(value)
		}
	}
	if command, ok := m.lookupCommand(value); ok && len(command.Params) > 0 {
		return value + " "
	}
	return value
}
func splitCommandWords(s string) ([]string, error) {
	var words []string
	var b strings.Builder
	var quote rune
	escape, active := false, false
	for _, r := range s {
		if escape {
			b.WriteRune(r)
			escape = false
			active = true
			continue
		}
		if r == '\\' {
			escape = true
			active = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				b.WriteRune(r)
			}
			active = true
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			active = true
			continue
		}
		if r == ' ' || r == '\t' {
			if active {
				words = append(words, b.String())
				b.Reset()
				active = false
			}
			continue
		}
		b.WriteRune(r)
		active = true
	}
	if quote != 0 || escape {
		return nil, fmt.Errorf("unterminated command quote")
	}
	if active {
		words = append(words, b.String())
	}
	return words, nil
}
func typedCommandValue(raw, kind string) (any, error) {
	switch kind {
	case "int":
		return strconv.ParseInt(raw, 10, 64)
	case "bool":
		return strconv.ParseBool(raw)
	case "strs":
		return strings.Split(raw, ","), nil
	default:
		return raw, nil
	}
}
func registeredCommandArgs(command registeredCommand, raw string) (map[string]any, error) {
	words, err := splitCommandWords(raw)
	if err != nil {
		return nil, err
	}
	args := map[string]any{}
	var positional []registeredCommandParam
	named := map[string]registeredCommandParam{}
	for _, p := range command.Params {
		if p.Positional {
			positional = append(positional, p)
		} else {
			named[p.Name] = p
		}
		if len(p.Default) > 0 {
			var value any
			if json.Unmarshal(p.Default, &value) == nil {
				args[p.Name] = value
			}
		}
	}
	position := 0
	for i := 0; i < len(words); i++ {
		word := words[i]
		var p registeredCommandParam
		var name, rawValue string
		if strings.HasPrefix(word, "--") {
			option := strings.TrimPrefix(word, "--")
			var inline bool
			name, rawValue, inline = strings.Cut(option, "=")
			var ok bool
			p, ok = named[name]
			if !ok {
				return nil, fmt.Errorf("unknown option --%s", name)
			}
			if !inline {
				if p.PType == "bool" {
					rawValue = "true"
				} else {
					if i+1 >= len(words) {
						return nil, fmt.Errorf("missing value for --%s", name)
					}
					i++
					rawValue = words[i]
				}
			}
		} else {
			if position >= len(positional) {
				return nil, fmt.Errorf("too many command arguments")
			}
			p = positional[position]
			position++
			name = p.Name
			rawValue = word
		}
		value, err := typedCommandValue(rawValue, p.PType)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		args[name] = value
	}
	for _, p := range command.Params {
		value, ok := args[p.Name]
		if p.Required && !ok {
			return nil, fmt.Errorf("missing required parameter %s", p.Name)
		}
		if ok && len(p.Choices) > 0 {
			if text, yes := value.(string); yes {
				found := false
				for _, choice := range p.Choices {
					if text == choice {
						found = true
						break
					}
				}
				if !found {
					return nil, fmt.Errorf("invalid %s value %q", p.Name, text)
				}
			}
		}
	}
	return args, nil
}
func (m *model) invokeDynamicCommand(input string) tea.Cmd {
	fields, err := splitCommandWords(input)
	if err != nil {
		m.err = err.Error()
		return nil
	}
	if len(fields) == 0 {
		return nil
	}
	definition, ok := m.lookupCommand(fields[0])
	if !ok {
		m.err = "unknown command: " + fields[0]
		return nil
	}
	raw := strings.TrimSpace(strings.TrimPrefix(input, fields[0]))
	args, err := registeredCommandArgs(definition, raw)
	if err != nil {
		m.err = err.Error()
		return nil
	}
	if m.host == nil {
		m.err = "Posoco is not connected"
		return nil
	}
	m.nextCommandRequest++
	id := fmt.Sprintf("command-%d", m.nextCommandRequest)
	m.status = "running /" + definition.ID
	return request(m.host, "invoke_command", map[string]any{
		"session_id": m.session, "id": definition.ID, "arguments": args, "request_id": id,
	})
}
func (m *model) handleCommandCompletion(raw json.RawMessage) {
	var data struct {
		CommandID string `json:"command_id"`
		Outcome   struct {
			Type     string `json:"type"`
			Feedback string `json:"feedback"`
			Reason   string `json:"reason"`
			Prompt   string `json:"prompt"`
		} `json:"outcome"`
	}
	if json.Unmarshal(raw, &data) != nil {
		return
	}
	switch data.Outcome.Type {
	case "success":
		m.status = "/" + data.CommandID + " complete"
		if data.Outcome.Feedback != "" {
			m.transcript = append(m.transcript, data.Outcome.Feedback)
		}
	case "failure":
		m.err = "/" + data.CommandID + ": " + data.Outcome.Reason
	case "needs_input":
		m.status = data.Outcome.Prompt
		if definition, found := m.lookupCommand("/" + data.CommandID); found {
			m.textarea.SetValue("/" + definition.ID + " ")
			m.textarea.Focus()
		}
	}
}
