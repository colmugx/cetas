package i18n

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLanguagesAndFallback(t *testing.T) {
	if value := For("zh-CN", "welcome.tagline"); !strings.Contains(value, "智能体") {
		t.Fatal(value)
	}
	if value := For("fr", "welcome.tagline"); value != "One agent. Every surface." {
		t.Fatal(value)
	}
	if Normalize("zh_CN.UTF-8") != "zh-CN" || Normalize("en_GB") != "en-US" {
		t.Fatal("normalization")
	}
}
func TestResolveAndSave(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, ".cetas", "settings.json")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{\"providers\":{\"key\":\"original\"},\"ui\":{\"theme\":\"dark\"}}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := Save(home, "zh-CN"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "\"key\": \"original\"") || !strings.Contains(string(data), "\"theme\": \"dark\"") {
		t.Fatalf("settings lost data: %s %v", data, err)
	}
	language, rest, err := Resolve([]string{"--lang", "en-US", "--version"}, func(string) string { return "" }, home)
	if err != nil || language != "en-US" || len(rest) != 1 || rest[0] != "--version" {
		t.Fatalf("flags: %s %#v %v", language, rest, err)
	}
	language, _, err = Resolve(nil, func(string) string { return "" }, home)
	if err != nil || language != "zh-CN" {
		t.Fatalf("stored: %s %v", language, err)
	}
}
