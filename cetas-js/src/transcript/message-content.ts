/**
 * Structural helpers shared by transcript replay and rewind.
 * Both paths must interpret saved text/image blocks the same way.
 */

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export interface MessageContent {
  text: string;
  hasImage: boolean;
}

export function textOfContent(content: unknown): MessageContent {
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
