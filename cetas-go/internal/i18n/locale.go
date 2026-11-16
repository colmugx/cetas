package i18n

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
)

var current atomic.Value

func init() { current.Store("en-US") }

func Current() string   { return current.Load().(string) }
func Set(locale string) { current.Store(locale) }
func Normalize(raw string) string {
	raw = strings.ToLower(strings.ReplaceAll(strings.TrimSpace(strings.SplitN(strings.SplitN(raw, ".", 2)[0], "@", 2)[0]), "_", "-"))
	if raw == "zh" || strings.HasPrefix(raw, "zh-") {
		return "zh-CN"
	}
	if raw == "en" || strings.HasPrefix(raw, "en-") {
		return "en-US"
	}
	return ""
}
func For(locale, key string) string {
	if translated, ok := catalog[locale][key]; ok {
		return translated
	}
	if fallback, ok := catalog["en-US"][key]; ok {
		return fallback
	}
	return key
}
func T(key string) string { return For(Current(), key) }
func Or(key, fallback string) string {
	if value, ok := catalog[Current()][key]; ok {
		return value
	}
	return fallback
}
func Format(key string, params map[string]any) string {
	value := T(key)
	for name, arg := range params {
		value = strings.ReplaceAll(value, "{"+name+"}", fmt.Sprint(arg))
	}
	return value
}
func settingsFile(home string) string { return filepath.Join(home, ".cetas", "settings.json") }
func ReadPreference(home string) (string, error) {
	content, err := os.ReadFile(settingsFile(home))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	content = []byte(strings.TrimPrefix(string(content), "\uFEFF"))
	var root map[string]json.RawMessage
	if err := json.Unmarshal(content, &root); err != nil {
		return "", err
	}
	if root == nil {
		return "", errors.New("settings.json must be an object")
	}
	rawUI, ok := root["ui"]
	if !ok {
		return "", nil
	}
	var ui map[string]json.RawMessage
	if err := json.Unmarshal(rawUI, &ui); err != nil {
		return "", fmt.Errorf("settings.ui: %w", err)
	}
	if ui == nil {
		return "", errors.New("settings.ui must be an object")
	}
	rawLocale, ok := ui["locale"]
	if !ok {
		return "", nil
	}
	var preference string
	if err := json.Unmarshal(rawLocale, &preference); err != nil {
		return "", fmt.Errorf("settings.ui.locale: %w", err)
	}
	if preference == "auto" || preference == "" {
		return "", nil
	}
	locale := Normalize(preference)
	if locale == "" {
		return "", fmt.Errorf("unsupported settings.ui.locale: %q", preference)
	}
	return locale, nil
}

// Resolve consumes --lang without changing the flags used by the composition root.
func Resolve(args []string, getenv func(string) string, home string) (locale string, remaining []string, err error) {
	var flag string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--lang":
			if i+1 == len(args) {
				return "", nil, errors.New("--lang requires en-US or zh-CN")
			}
			i++
			flag = args[i]
		case strings.HasPrefix(args[i], "--lang="):
			flag = strings.TrimPrefix(args[i], "--lang=")
		default:
			remaining = append(remaining, args[i])
		}
	}
	if flag != "" && flag != "auto" {
		if locale = Normalize(flag); locale == "" {
			return "", nil, fmt.Errorf("unsupported --lang: %q", flag)
		}
		return locale, remaining, nil
	}
	if value := getenv("CETAS_LANG"); value != "" && value != "auto" {
		if locale = Normalize(value); locale == "" {
			return "", nil, fmt.Errorf("unsupported CETAS_LANG: %q", value)
		}
		return locale, remaining, nil
	}
	locale, err = ReadPreference(home)
	if err != nil || locale != "" {
		return locale, remaining, err
	}
	for _, key := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if locale = Normalize(getenv(key)); locale != "" {
			return locale, remaining, nil
		}
	}
	return "en-US", remaining, nil
}
func Save(home, locale string) error {
	if Normalize(locale) != locale {
		return fmt.Errorf("unsupported locale %q", locale)
	}
	dir := filepath.Dir(settingsFile(home))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	root := map[string]json.RawMessage{}
	data, err := os.ReadFile(settingsFile(home))
	if err == nil {
		if err = json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\uFEFF")), &root); err != nil {
			return err
		}
		if root == nil {
			return errors.New("settings.json must be an object")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if len(root) == 0 && errors.Is(err, os.ErrNotExist) {
		root["providers"] = json.RawMessage("{}")
	}
	ui := map[string]json.RawMessage{}
	if raw, ok := root["ui"]; ok {
		if err := json.Unmarshal(raw, &ui); err != nil {
			return err
		}
		if ui == nil {
			return errors.New("settings.ui must be an object")
		}
	}
	rawLocale, _ := json.Marshal(locale)
	ui["locale"] = rawLocale
	rawUI, err := json.Marshal(ui)
	if err != nil {
		return err
	}
	root["ui"] = rawUI
	updated, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".settings-language-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err != nil {
		file.Close()
		return err
	}
	if _, err = file.Write(append(updated, '\n')); err != nil {
		file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), settingsFile(home))
}
