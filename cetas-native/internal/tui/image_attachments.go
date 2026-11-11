package tui

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// Image attachment input, mirroring the JS host's image-attachments.ts: an
// `@path` mention that resolves to a workspace image file rides the turn as
// an inline base64 Image block while the text mention stays in the prompt.
// Pasted images (an empty bracketed paste with an image on the system
// clipboard) stage the same way. Guardrails: one attachment per path, a
// decoded-size cap, and warnings rendered as notices instead of exceptions.

const maxImageBytes = 5 * 1024 * 1024

var imageMentionExts = map[string]string{
	".png":  "image/png",
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".gif":  "image/gif",
	".webp": "image/webp",
}

type imageAttachment struct {
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
	// Label is display-only: the file name or "clipboard".
	Label string `json:"-"`
	Bytes int    `json:"-"`
}

var imageMentionPattern = regexp.MustCompile(`(?:^|\s)@([^\s@]+)`)

// findImageMentions returns `@`-tokens whose extension looks like an image,
// with the JS host's trim rules (surrounding quotes/brackets and trailing
// punctuation are not part of the path).
func findImageMentions(prompt string) []string {
	var tokens []string
	for _, match := range imageMentionPattern.FindAllStringSubmatch(prompt, -1) {
		token := strings.TrimLeft(match[1], "(\"'{")
		token = strings.TrimRight(token, ")\"']},.:;!?")
		if _, ok := imageMentionExts[strings.ToLower(filepath.Ext(token))]; ok {
			tokens = append(tokens, token)
		}
	}
	return tokens
}

// resolveImageMentions reads every image mention that resolves against the
// workspace directory. Failures are warnings, never exceptions: the prompt
// still goes out with its text mentions.
func resolveImageMentions(prompt, cwd string) (attachments []imageAttachment, warnings []string) {
	seen := map[string]bool{}
	for _, token := range findImageMentions(prompt) {
		if seen[token] {
			continue
		}
		seen[token] = true
		candidate := filepath.Join(cwd, filepath.FromSlash(token))
		data, err := os.ReadFile(candidate)
		if err != nil {
			warnings = append(warnings, "@"+token+": no matching workspace image file; not attached")
			continue
		}
		if len(data) > maxImageBytes {
			warnings = append(warnings, fmt.Sprintf("@%s: %s exceeds the 5 MB attachment limit; not attached", token, formatImageBytes(len(data))))
			continue
		}
		mediaType := imageMentionExts[strings.ToLower(filepath.Ext(token))]
		attachments = append(attachments, imageAttachment{
			MediaType: mediaType,
			Data:      base64.StdEncoding.EncodeToString(data),
			Label:     token,
			Bytes:     len(data),
		})
	}
	return attachments, warnings
}

func formatImageBytes(size int) string {
	if size >= 1024*1024 {
		return fmt.Sprintf("%.1f MB", float64(size)/(1024*1024))
	}
	return fmt.Sprintf("%d KB", max(1, size/1024))
}

// readClipboardImage is the platform clipboard probe; tests replace it. An
// empty paste with an image on the clipboard is how terminals deliver "the
// user pasted an image" — no bytes cross stdin.
var readClipboardImage = func() (imageAttachment, bool) {
	if !clipboardImageSupported() {
		return imageAttachment{}, false
	}
	out, err := exec.Command("osascript", "-e", "the clipboard as «class PNGf»").Output()
	if err != nil {
		return imageAttachment{}, false
	}
	data := decodeAppleScriptPNG(string(out))
	if len(data) == 0 || len(data) > maxImageBytes {
		return imageAttachment{}, false
	}
	return imageAttachment{
		MediaType: "image/png",
		Data:      base64.StdEncoding.EncodeToString(data),
		Label:     "clipboard.png",
		Bytes:     len(data),
	}, true
}

func clipboardImageSupported() bool {
	if os.Getenv("CETAS_NATIVE_DISABLE_IMAGE_PASTE") != "" {
		return false
	}
	return runtime.GOOS == "darwin"
}

// decodeAppleScriptPNG parses «data PNGf<hex>;» output into raw bytes.
func decodeAppleScriptPNG(out string) []byte {
	open := strings.Index(out, "PNGf")
	if open < 0 {
		return nil
	}
	hexBody := out[open+4:]
	if end := strings.IndexAny(hexBody, ";\n\r»"); end >= 0 {
		hexBody = hexBody[:end]
	}
	data, err := hex.DecodeString(strings.TrimSpace(hexBody))
	if err != nil {
		return nil
	}
	// AppleScript hex is a PNG file image; the magic is the cheapest truth.
	if len(data) < 8 || string(data[:4]) != "\x89PNG" {
		return nil
	}
	return data
}

// stageImageAttachments merges newly resolved attachments into the staged
// set, deduped by label.
func (m *model) stageImageAttachments(attachments []imageAttachment) {
	for _, attachment := range attachments {
		duplicate := false
		for _, existing := range m.pendingImages {
			if existing.Label == attachment.Label {
				duplicate = true
				break
			}
		}
		if !duplicate {
			m.pendingImages = append(m.pendingImages, attachment)
		}
	}
}

// stagedImageSummary renders the chip line the status area shows while
// attachments wait for the next submit.
func (m *model) stagedImageSummary() string {
	if len(m.pendingImages) == 0 {
		return ""
	}
	labels := make([]string, 0, len(m.pendingImages))
	for _, attachment := range m.pendingImages {
		labels = append(labels, fmt.Sprintf("🖼 %s (%s)", attachment.Label, formatImageBytes(attachment.Bytes)))
	}
	return strings.Join(labels, " ") + " — Enter sends, Esc clears"
}
