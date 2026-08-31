/**
 * Session replay: parse a persisted session transcript into display items.
 *
 * The on-disk format is posoco-ext-fs-session's JSONL — one message per
 * line, `role`-tagged (`system`/`user`/`assistant`/`tool`), content as an
 * array of `{type:"text"|"image", …}` blocks, assistant `tool_calls` keyed
 * by legacy disk names (`id`/`name`/`arguments`), tool results carrying
 * `tool_call_id`. Parsing is lenient per line: one malformed record skips
 * that record, never the replay.
 */

export type ReplayItem =
  | { kind: "user"; text: string; hasImage: boolean }
  | { kind: "reasoning"; text: string }
  | { kind: "assistant"; text: string }
  | {
      kind: "tool_call";
      toolCallId: string;
      toolName: string;
      args: unknown;
    }
  | {
      kind: "tool_result";
      toolCallId: string;
      toolName?: string;
      content: string;
      isError: boolean;
    };

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Tool results arrive after their call; carry the pending name forward. */
export function parseSessionReplay(jsonl: string): ReplayItem[] {
  const items: ReplayItem[] = [];
  // tool_call id → name, so result rows can show which tool produced them.
  const callNames = new Map<string, string>();
  for (const rawLine of jsonl.split("\n")) {
    const line = rawLine.trim();
    if (line.length === 0) continue;
    let rec: unknown;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (!isRecord(rec)) continue;
    const role = rec.role;
    switch (role) {
      case "user": {
        const { text, hasImage } = textOfContent(rec.content);
        if (text.length > 0 || hasImage) {
          items.push({ kind: "user", text, hasImage });
        }
        break;
      }
      case "system":
        // System prompts are composition state, not conversation history.
        break;
      case "assistant": {
        const reasoning = typeof rec.reasoning_content === "string"
          ? rec.reasoning_content
          : undefined;
        if (reasoning !== undefined) {
          items.push({ kind: "reasoning", text: reasoning });
        }
        if (Array.isArray(rec.tool_calls)) {
          for (const call of rec.tool_calls) {
            if (!isRecord(call)) continue;
            const id = typeof call.id === "string"
              ? call.id
              : typeof call.call_id === "string"
              ? call.call_id
              : undefined;
            const name = typeof call.name === "string" ? call.name : undefined;
            if (id === undefined || name === undefined) continue;
            callNames.set(id, name);
            items.push({
              kind: "tool_call",
              toolCallId: id,
              toolName: name,
              args: call.arguments,
            });
          }
        }
        const { text } = textOfContent(rec.content);
        if (text.length > 0) {
          items.push({ kind: "assistant", text });
        }
        break;
      }
      case "tool": {
        const id = typeof rec.tool_call_id === "string" ? rec.tool_call_id : undefined;
        if (id === undefined) break;
        const content = textOfContent(rec.content).text;
        items.push({
          kind: "tool_result",
          toolCallId: id,
          toolName: typeof rec.name === "string" ? rec.name : callNames.get(id),
          content,
          // The fs-session JSONL format persists no error marker for tool
          // results, so replay cannot recover error-ness; rows render
          // neutral. Fixing this requires extending the on-disk format
          // (tracked as an open question).
          isError: false,
        });
        break;
      }
      default:
        break;
    }
  }
  return items;
}
