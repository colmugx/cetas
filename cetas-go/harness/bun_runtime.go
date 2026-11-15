package harness

// Bun is an optional, downloaded runtime for experimental Pi guests.
// It is never part of the Cetas release bundle or a requirement at startup.
import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const experimentalBunVersion = "1.4.4"
const bunArchiveLimit int64 = 160 << 20
const bunExecutableLimit int64 = 140 << 20

// SHA-256 of the official Bun release archives, pinned with the runtime version.
// Values are the digest fields on GitHub's bun-v1.4.4 release assets.
var experimentalBunChecksums = map[string]string{
	"bun-darwin-aarch64.zip":       "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510",
	"bun-linux-x64-baseline.zip":   "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76",
	"bun-linux-aarch64.zip":        "baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e",
	"bun-windows-x64-baseline.zip": "0f20ce6674d4f2dbcc8c5d59fdf99f7ba45f8c3b367e0f5781cbfa30a1c78d99",
}
var bunDownloadMu sync.Mutex

func bunArtifactFor(goos, goarch string) (string, error) {
	switch goos + "/" + goarch {
	case "darwin/arm64":
		return "bun-darwin-aarch64.zip", nil
	case "linux/amd64":
		return "bun-linux-x64-baseline.zip", nil
	case "linux/arm64":
		return "bun-linux-aarch64.zip", nil
	case "windows/amd64":
		return "bun-windows-x64-baseline.zip", nil
	default:
		return "", fmt.Errorf("experimental Bun is unavailable for %s/%s", goos, goarch)
	}
}
func bunExecutable(goos string) string {
	if goos == "windows" {
		return "bun.exe"
	}
	return "bun"
}
func bunCachePath(home, artifact string) string {
	target := strings.TrimSuffix(artifact, ".zip")
	return filepath.Join(home, ".cetas", "runtimes", "bun", experimentalBunVersion, target, bunExecutable(runtime.GOOS))
}

func bunPrepared(home string) (string, bool, error) {
	artifact, err := bunArtifactFor(runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return "", false, err
	}
	path := bunCachePath(home, artifact)
	stat, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return path, false, nil
	}
	if err != nil {
		return path, false, err
	}
	if !stat.Mode().IsRegular() {
		return path, false, fmt.Errorf("cached Bun is not a regular file: %s", path)
	}
	return path, true, nil
}

// prepareBun explicitly downloads a pinned, verified official zip.
// The cache path is versioned; a failed download cannot replace a working binary.
func prepareBun(ctx context.Context, home string) (string, error) {
	bunDownloadMu.Lock()
	defer bunDownloadMu.Unlock()
	path, ready, err := bunPrepared(home)
	if err != nil {
		return "", err
	}
	if ready {
		return path, nil
	}
	artifact, err := bunArtifactFor(runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return "", err
	}
	want := experimentalBunChecksums[artifact]
	if want == "" {
		return "", fmt.Errorf("missing pinned Bun checksum for %s", artifact)
	}
	url := "https://github.com/oven-sh/bun/releases/download/bun-v" + experimentalBunVersion + "/" + artifact
	client := &http.Client{Timeout: 3 * time.Minute}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	response, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("download Bun %s: %w", artifact, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download Bun %s: %s", artifact, response.Status)
	}
	archive, err := io.ReadAll(io.LimitReader(response.Body, bunArchiveLimit+1))
	if err != nil {
		return "", err
	}
	if int64(len(archive)) > bunArchiveLimit {
		return "", errors.New("Bun archive exceeds size limit")
	}
	hash := sha256.Sum256(archive)
	if hex.EncodeToString(hash[:]) != want {
		return "", errors.New("Bun archive SHA-256 mismatch")
	}
	zr, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		return "", err
	}
	filename := bunExecutable(runtime.GOOS)
	var selected *zip.File
	for _, entry := range zr.File {
		if entry.FileInfo().IsDir() || filepath.Base(entry.Name) != filename {
			continue
		}
		if selected != nil {
			return "", errors.New("Bun archive contains multiple executable entries")
		}
		selected = entry
	}
	if selected == nil {
		return "", fmt.Errorf("Bun archive contains no %s", filename)
	}
	if selected.UncompressedSize64 > uint64(bunExecutableLimit) {
		return "", errors.New("Bun executable exceeds size limit")
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return "", err
	}
	output, err := os.CreateTemp(filepath.Dir(path), ".bun-*.part")
	if err != nil {
		return "", err
	}
	tmp := output.Name()
	defer os.Remove(tmp)
	src, err := selected.Open()
	if err != nil {
		output.Close()
		return "", err
	}
	_, copyErr := io.Copy(output, io.LimitReader(src, bunExecutableLimit+1))
	closeErr := src.Close()
	if copyErr != nil || closeErr != nil {
		output.Close()
		return "", fmt.Errorf("extract Bun: %v / %v", copyErr, closeErr)
	}
	if err = output.Chmod(0700); err != nil {
		output.Close()
		return "", err
	}
	if err = output.Close(); err != nil {
		return "", err
	}
	if err = os.Rename(tmp, path); err != nil {
		return "", err
	}
	return path, nil
}
