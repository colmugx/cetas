package hawdbacceptance

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "net/http/httptest"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"

    "github.com/colmugx/cetas/cetas-go/harness"
)

func TestHawdbNativeSessionFlow(t *testing.T) {
    home := t.TempDir()
    project := t.TempDir()
    t.Chdir(project)
    if err := os.MkdirAll(filepath.Join(home, ".cetas"), 0700); err != nil { t.Fatal(err) }
    llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path != "/v1/chat/completions" { http.NotFound(w, r); return }
        _, _ = io.Copy(io.Discard, r.Body)
        w.Header().Set("Content-Type", "text/event-stream")
        _, _ = io.WriteString(w, "data: "+`{"id":"hawdb-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Persisted in HawDB"},"finish_reason":null}]}`+"\n\n")
        _, _ = io.WriteString(w, "data: "+`{"id":"hawdb-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`+"\n\n")
        _, _ = io.WriteString(w, "data: [DONE]\n\n")
        if flush, ok := w.(http.Flusher); ok { flush.Flush() }
    }))
    defer llm.Close()
    settings := []byte(fmt.Sprintf(`{"providers":{"hawdb-test":{"base_url":%q,"model":"hawdb-integration","api_key":"fake"}}}`, llm.URL+"/v1"))
    if err := os.WriteFile(filepath.Join(home, ".cetas", "settings.json"), settings, 0600); err != nil { t.Fatal(err) }
    t.Setenv("CETAS_HOME", home)
    t.Setenv("CETAS_SESSION_BACKEND", "hawdb")
    ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
    defer cancel()
    h, err := harness.Start(ctx)
    if err != nil { t.Fatal(err) }
    t.Cleanup(func() {
        done, end := context.WithTimeout(context.Background(), 15*time.Second)
        defer end()
        if err := h.Close(done); err != nil { t.Errorf("shutdown: %v", err) }
    })
    frame, err := h.Request(ctx, "runtime_state", map[string]any{})
    if err != nil { t.Fatal(err) }
    var current map[string]any
    if err := json.Unmarshal(frame, &current); err != nil { t.Fatal(err) }
    sessionID, _ := current["session_id"].(string)
    if sessionID == "" { t.Fatalf("missing session_id: %s", frame) }
    if _, err := h.Request(ctx, "turn_start", map[string]any{"prompt":"Test HawDB persistence"}); err != nil { t.Fatal(err) }
    completed := false
    for !completed {
        select {
        case event := <-h.Events():
            if event.Type == "turn.failed" { t.Fatalf("agent failed: %s", event.Raw) }
            if event.Type == "turn.completed" { completed = true }
        case <-ctx.Done():
            t.Fatal("HawDB turn incomplete", ctx.Err())
        }
    }
    catalog, err := h.Request(ctx, "session_catalog", map[string]any{"scope":"current","limit":20})
    if err != nil { t.Fatal(err) }
    if !strings.Contains(string(catalog), sessionID) { t.Fatalf("missing HawDB catalog session: %s", catalog) }
    replay, err := h.Request(ctx, "transcript_index", map[string]any{"session_id":sessionID})
    if err != nil { t.Fatal(err) }
    var index map[string]any
    if err := json.Unmarshal(replay, &index); err != nil { t.Fatal(err) }
    revision, _ := index["revision"].(string)
    total, _ := index["total"].(float64)
    if revision == "" || total < 2 || index["error"] != nil {
        t.Fatalf("invalid HawDB transcript index: %s", replay)
    }
    page, err := h.Request(ctx, "transcript_page", map[string]any{
        "session_id":sessionID,"revision":revision,"first":0,"limit":50,
    })
    if err != nil || !strings.Contains(string(page), "Persisted in HawDB") {
        t.Fatalf("HawDB transcript page: %s (%v)", page, err)
    }
    points, err := h.Request(ctx, "rewind_points", map[string]any{})
    if err != nil || !strings.Contains(string(points), "message_index") {
        t.Fatalf("HawDB rewind points: %s (%v)", points, err)
    }
    if err := filepath.WalkDir(home, func(path string, entry os.DirEntry, err error) error {
        if err != nil { return err }
        if !entry.IsDir() && strings.HasSuffix(path, sessionID+".jsonl") {
            return fmt.Errorf("unexpected filesystem session: %s", path)
        }
        return nil
    }); err != nil { t.Fatal(err) }
}
