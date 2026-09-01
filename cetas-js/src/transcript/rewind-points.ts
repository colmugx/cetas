/**
 * Rewind-point enumeration over a persisted session transcript.
 *
 * The on-disk format is posoco-ext-fs-session's JSONL: physical line 0 is
 * the metadata object and every line after it is one message, so physical
 * line i (i >= 1) addresses `messages[i - 1]` in the loaded session.
 * Addressing MUST advance by physical line — blank and malformed lines are
 * skipped as rewind points but still occupy their slot; counting only the
 * successfully parsed lines would misalign every index after a skipped
 * line and make the host truncate the wrong message.
 */

export interface RewindPoint {
  /** Index into the session's `messages` array (physical line minus the metadata header). */
  messageIndex: number;
  /** Flat single-line preview of the message text, image-only rows marked "(image)". */
  preview: string;
}

const PREVIEW_MAX = 60;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function textOfContent(content: unknown): { text: string; hasImage: boolean } {
  if (!Array.isArray(content)) return { text: "", hasImage: false };
  const parts: string[] = [];
  let hasImage = false;
  for (const block of content) {
    if (typeof block !== "object" || block === null) continue;
    const b = block as Record<string, unknown>;
    if (b.type === "text" && typeof b.text === "string") {
      parts.push(b.text);
    } else if (b.type === "image") {
      hasImage = true;
    }
  }
  return { text: parts.join("\n"), hasImage };
}

function previewOf(text: string, hasImage: boolean): string {
  const flat = text.replace(/\s+/g, " ").trim();
  const parts = flat.length > 0 ? [flat] : [];
  if (hasImage) parts.push("(image)");
  const joined = parts.join(" ");
  return joined.length > PREVIEW_MAX ? `${joined.slice(0, PREVIEW_MAX - 1)}…` : joined;
}

/**
 * Full text of the user message at `messageIndex` — the editor-refill
 * counterpart of `listRewindPoints`, whose previews are truncated. Same
 * physical-line addressing; multi-line text keeps its newlines. Out-of-range,
 * blank/malformed, and non-user rows return null; an image-only user message
 * yields "" (there is no text to refill).
 */
export function readUserMessage(jsonl: string, messageIndex: number): string | null {
  const line = jsonl.split("\n")[messageIndex + 1]?.trim();
  if (line === undefined || line.length === 0) return null;
  let rec: unknown;
  try {
    rec = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(rec) || rec.role !== "user") return null;
  return textOfContent(rec.content).text;
}

/** User-message rewind points in transcript order, addressed by message index. */
export function listRewindPoints(jsonl: string): RewindPoint[] {
  const points: RewindPoint[] = [];
  const lines = jsonl.split("\n");
  // Physical line 0 is the metadata header, never a message.
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) continue;
    let rec: unknown;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (!isRecord(rec) || rec.role !== "user") continue;
    const { text, hasImage } = textOfContent(rec.content);
    // Guard on the flattened preview so whitespace-only rows don't render blank.
    const preview = previewOf(text, hasImage);
    if (preview.length === 0) continue;
    points.push({ messageIndex: i - 1, preview });
  }
  return points;
}
