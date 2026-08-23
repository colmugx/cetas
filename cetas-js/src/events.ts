/**
 * events.ts — wire protocol between the MoonBit Observer bridge and the
 * cetas-js TUI.
 *
 * Why a union rather than a single `{type, payload}` shape: it lets the
 * event-router exhaustively switch on `ev.type` so adding a new variant
 * surfaces unhandled branches at compile time. The MoonBit side
 * (`turn_event_to_json` in lib/cetas_js.mbt) must emit one of these tags.
 *
 * Push-model note: `message_update` carries the
 * FULL accumulated assistant message, not a delta. The streaming-ui
 * controller throttles re-renders so the cost of full replacement is paid
 * at most once per STREAMING_UI_FLUSH_MS.
 */

import { parseUiRender, type UiRender } from "../ui/extension-ui.ts";

/** A single text or reasoning block inside an assistant message. */
export interface BridgeContentBlock {
  type: "text";
  text: string;
}

export interface BridgeImageBlock {
  type: "image";
  url: string;
  mime: string;
}

/** Assistant message — push in full on every update. */
export interface BridgeMessage {
  role: "assistant";
  content: Array<BridgeContentBlock | BridgeImageBlock>;
  /** Optional model-side reasoning (DeepSeek `reasoning_content`). */
  reasoning?: string;
  /** Present when the model emitted one or more tool calls in this message. */
  toolCalls?: BridgeToolCallRef[];
}

/** Tool-call reference carried on the assistant message. */
export interface BridgeToolCallRef {
  id: string;
  name: string;
  /** Raw arguments — usually a JSON string per OpenAI spec. */
  arguments: string;
}

/** Token usage from the provider, when reported. */
export interface BridgeUsage {
  input_tokens?: number;
  output_tokens?: number;
  reasoning_tokens?: number;
}

export type CetasEvent =
  | { type: "turn_started" }
  | { type: "turn_completed" }
  | {
      type: "turn_failed";
      error_message: string;
      error_kind: string;
    }
  | { type: "message_end"; message: BridgeMessage }
  | {
      type: "tool_call_started";
      tool_call_id: string;
      tool_name: string;
      args: unknown;
    }
  | {
      type: "tool_call_completed";
      tool_call_id: string;
      result: string;
      is_error: boolean;
      /** Machine-readable ToolOutcome.structured (reserved `summary` field). */
      structured?: Record<string, unknown>;
    }
  | {
      type: "tool_call_deferred";
      tool_call_id: string;
      tool_name: string;
      reason: string;
    }
  | {
      type: "session_redirect";
      from: string;
      to: string;
    }
  | {
      type: "model_invoked";
      model: string;
      usage?: BridgeUsage;
    }
  | {
      type: "stream_chunk";
      raw: string;
      kind: "text" | "reasoning";
    }
  | {
      type: "custom";
      source: string;
      label: string;
      data?: unknown;
    }
  | {
      type: "config_changed";
      field: string;
      old: string;
      new: string;
    }
  | {
      type: "config_warning";
      field: string;
      value: string;
      reason: string;
    }
  | { type: "ui_render"; render: UiRender };

function requireString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`${path} must be a string`);
  }
  return value;
}

function requireBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`${path} must be a boolean`);
  }
  return value;
}

function requireRecord(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function parseUsage(value: unknown): BridgeUsage | undefined {
  if (value === undefined || value === null) return undefined;
  const usage = requireRecord(value, "model_invoked.usage");
  const result: BridgeUsage = {};
  for (const [wireKey, targetKey] of [
    ["input_tokens", "input_tokens"],
    ["output_tokens", "output_tokens"],
    ["reasoning_tokens", "reasoning_tokens"],
  ] as const) {
    const tokenCount = usage[wireKey];
    if (tokenCount === undefined) continue;
    if (
      typeof tokenCount !== "number" ||
      !Number.isInteger(tokenCount) ||
      tokenCount < 0
    ) {
      throw new Error(`model_invoked.usage.${wireKey} must be a non-negative integer`);
    }
    result[targetKey] = tokenCount;
  }
  return result;
}

function parseBridgeMessage(value: unknown): BridgeMessage {
  const message = requireRecord(value, "message_end.message");
  if (message.role !== "assistant") {
    throw new Error("message_end.message.role must be assistant");
  }
  if (!Array.isArray(message.content)) {
    throw new Error("message_end.message.content must be an array");
  }
  const content = message.content.map((rawBlock, index) => {
    const block = requireRecord(
      rawBlock,
      `message_end.message.content[${index}]`,
    );
    if (block.type === "text") {
      return {
        type: "text" as const,
        text: requireString(
          block.text,
          `message_end.message.content[${index}].text`,
        ),
      };
    }
    if (block.type === "image") {
      return {
        type: "image" as const,
        url: requireString(
          block.url,
          `message_end.message.content[${index}].url`,
        ),
        mime: requireString(
          block.mime,
          `message_end.message.content[${index}].mime`,
        ),
      };
    }
    throw new Error(`message_end.message.content[${index}].type is unknown`);
  });
  const result: BridgeMessage = { role: "assistant", content };
  if (message.reasoning !== undefined) {
    result.reasoning = requireString(
      message.reasoning,
      "message_end.message.reasoning",
    );
  }
  if (message.toolCalls !== undefined) {
    if (!Array.isArray(message.toolCalls)) {
      throw new Error("message_end.message.toolCalls must be an array");
    }
    result.toolCalls = message.toolCalls.map((rawToolCall, index) => {
      const toolCall = requireRecord(
        rawToolCall,
        `message_end.message.toolCalls[${index}]`,
      );
      return {
        id: requireString(
          toolCall.id,
          `message_end.message.toolCalls[${index}].id`,
        ),
        name: requireString(
          toolCall.name,
          `message_end.message.toolCalls[${index}].name`,
        ),
        arguments: requireString(
          toolCall.arguments,
          `message_end.message.toolCalls[${index}].arguments`,
        ),
      };
    });
  }
  return result;
}

function requireStreamKind(value: unknown): "text" | "reasoning" {
  if (value === "text" || value === "reasoning") return value;
  throw new Error("stream_chunk.kind must be text or reasoning");
}

/** Narrow unknown JSON (from `JSON.parse(eventJson)`) into a CetasEvent. */
export function parseCetasEvent(raw: unknown): CetasEvent | null {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("cetas event must be an object");
  }
  const ev = raw as Record<string, unknown>;
  if (typeof ev.type !== "string") {
    throw new Error("cetas event.type must be a string");
  }
  switch (ev.type) {
    case "turn_started":
    case "turn_completed":
      return { type: ev.type };
    case "turn_failed":
      return {
        type: "turn_failed",
        error_message: requireString(ev.error_message, "turn_failed.error_message"),
        error_kind: requireString(ev.error_kind, "turn_failed.error_kind"),
      };
    case "message_end":
      return { type: "message_end", message: parseBridgeMessage(ev.message) };
    case "tool_call_started":
      return {
        type: "tool_call_started",
        tool_call_id: requireString(
          ev.tool_call_id,
          "tool_call_started.tool_call_id",
        ),
        tool_name: requireString(ev.tool_name, "tool_call_started.tool_name"),
        args: ev.args,
      };
    case "tool_call_completed": {
      const completed: CetasEvent = {
        type: "tool_call_completed",
        tool_call_id: requireString(
          ev.tool_call_id,
          "tool_call_completed.tool_call_id",
        ),
        result: requireString(ev.result, "tool_call_completed.result"),
        is_error: requireBoolean(
          ev.is_error,
          "tool_call_completed.is_error",
        ),
      };
      if (ev.structured !== undefined) {
        completed.structured = requireRecord(
          ev.structured,
          "tool_call_completed.structured",
        );
      }
      return completed;
    }
    case "tool_call_deferred":
      return {
        type: "tool_call_deferred",
        tool_call_id: requireString(
          ev.tool_call_id,
          "tool_call_deferred.tool_call_id",
        ),
        tool_name: requireString(ev.tool_name, "tool_call_deferred.tool_name"),
        reason: requireString(ev.reason, "tool_call_deferred.reason"),
      };
    case "session_redirect":
      return {
        type: "session_redirect",
        from: requireString(ev.from, "session_redirect.from"),
        to: requireString(ev.to, "session_redirect.to"),
      };
    case "model_invoked":
      return {
        type: "model_invoked",
        model: requireString(ev.model, "model_invoked.model"),
        usage: parseUsage(ev.usage),
      };
    case "stream_chunk":
      return {
        type: "stream_chunk",
        raw: requireString(ev.raw, "stream_chunk.raw"),
        kind: requireStreamKind(ev.kind),
      };
    case "custom":
      return {
        type: "custom",
        source: requireString(ev.source, "custom.source"),
        label: requireString(ev.label, "custom.label"),
        data: ev.data,
      };
    case "config_changed":
      return {
        type: "config_changed",
        field: requireString(ev.field, "config_changed.field"),
        old: requireString(ev.old, "config_changed.old"),
        new: requireString(ev.new, "config_changed.new"),
      };
    case "config_warning":
      return {
        type: "config_warning",
        field: requireString(ev.field, "config_warning.field"),
        value: requireString(ev.value, "config_warning.value"),
        reason: requireString(ev.reason, "config_warning.reason"),
      };
    case "ui_render":
      return { type: "ui_render", render: parseUiRender(ev.render) };
    default:
      return null;
  }
}
