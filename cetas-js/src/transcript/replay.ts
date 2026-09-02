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

// Machine-injected context, not user speech. Two shapes reach the disk as
// role:"user" records: posoco-devkit context envelopes that PipelineHook /
// MemoryPort extensions push before each model call (`<permission-context …>`,
// `<lazytools-context …>`, `<nmem-context …>`, …), and posoco's session-opening
// memory composite, whose "## Memory" lead line wraps the provider envelope.
// Rendering either on replay would show the user "sending" text they never
// typed, so both are skipped wherever persisted user messages are surfaced.
const ENVELOPE_PREFIX = /^<[A-Za-z][A-Za-z0-9-]*-context(?=[\s>])/;
const MEMORY_LEAD = /^##\s+Memory\b/;

export function isSyntheticUserText(text: string): boolean {
  const trimmed = text.trimStart();
  return ENVELOPE_PREFIX.test(trimmed) || MEMORY_LEAD.test(trimmed);
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
        if (isSyntheticUserText(text)) break;
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
          // New fs-session files persist `is_error: true` on failed tool
          // results (absent or false = success), so error-ness round-trips.
          // Legacy files lack the field and render neutral. Only a boolean
          // true counts; anything else (e.g. the string "true") does not.
          isError: rec.is_error === true,
        });
        break;
      }
      default:
        break;
    }
  }
  return items;
}
