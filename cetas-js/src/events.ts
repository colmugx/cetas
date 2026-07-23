/**
 * events.ts — wire protocol between the MoonBit Observer bridge and the
 * cetas-js TUI.
 *
 * Why a union rather than a single `{type, payload}` shape: it lets the
 * event-router exhaustively switch on `ev.type` so adding a new variant
 * surfaces unhandled branches at compile time. The MoonBit side
 * (`turn_event_to_json` in lib/cetas_js.mbt) must emit one of these tags.
 *
 * Push-model note (mirrors pi-coding-agent): `message_update` carries the
 * FULL accumulated assistant message, not a delta. The streaming-ui
 * controller throttles re-renders so the cost of full replacement is paid
 * at most once per STREAMING_UI_FLUSH_MS.
 */

/** A single text or reasoning block inside an assistant message. */
export interface BridgeContentBlock {
  type: "text" | "thinking";
  text: string;
}

/** Assistant message — push in full on every update. */
export interface BridgeMessage {
  role: "assistant";
  content: BridgeContentBlock[];
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
  | { type: "turn_started"; session_id: string }
  | { type: "turn_completed"; session_id: string }
  | {
      type: "turn_failed";
      session_id: string;
      error_message: string;
      error_kind: string;
    }
  | { type: "message_start"; message: BridgeMessage }
  | { type: "message_update"; message: BridgeMessage }
  | { type: "message_end"; message: BridgeMessage }
  | {
      type: "tool_call_started";
      tool_call_id: string;
      tool_name: string;
      args: unknown;
    }
  | {
      type: "tool_call_update";
      tool_call_id: string;
      partial_args?: unknown;
      partial_result?: string;
    }
  | {
      type: "tool_call_completed";
      tool_call_id: string;
      result: string;
      is_error: boolean;
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
    };

/** Narrow unknown JSON (from `JSON.parse(eventJson)`) into a CetasEvent. */
export function parseCetasEvent(raw: unknown): CetasEvent | null {
  if (typeof raw !== "object" || raw === null) return null;
  const ev = raw as Record<string, unknown>;
  switch (ev.type) {
    case "turn_started":
    case "turn_completed":
      return { type: ev.type, session_id: String(ev.session_id ?? "") };
    case "turn_failed":
      return {
        type: "turn_failed",
        session_id: String(ev.session_id ?? ""),
        error_message: String(ev.message ?? ev.error_message ?? ""),
        error_kind: String(ev.error_kind ?? "unknown"),
      };
    case "message_start":
    case "message_update":
    case "message_end":
      return { type: ev.type, message: ev.message as BridgeMessage };
    case "tool_call_started":
      return {
        type: "tool_call_started",
        tool_call_id: String(ev.tool_call_id ?? ev.id ?? ""),
        tool_name: String(ev.tool_name ?? ev.name ?? ""),
        args: ev.arguments ?? ev.args,
      };
    case "tool_call_update":
      return {
        type: "tool_call_update",
        tool_call_id: String(ev.tool_call_id ?? ev.id ?? ""),
        partial_args: ev.partial_args,
        partial_result:
          typeof ev.partial_result === "string" ? ev.partial_result : undefined,
      };
    case "tool_call_completed":
      return {
        type: "tool_call_completed",
        tool_call_id: String(ev.tool_call_id ?? ev.id ?? ""),
        result: String(ev.result ?? ev.content ?? ""),
        is_error: Boolean(ev.is_error),
      };
    case "tool_call_deferred":
      return {
        type: "tool_call_deferred",
        tool_call_id: String(ev.tool_call_id ?? ev.id ?? ""),
        tool_name: String(ev.tool_name ?? ev.name ?? ""),
        reason: String(ev.reason ?? ""),
      };
    case "session_redirect":
      return {
        type: "session_redirect",
        from: String(ev.from ?? ""),
        to: String(ev.to ?? ""),
      };
    case "model_invoked":
    case "model_response":
      // posoco's TurnEvent::ModelResponseReceived currently surfaces as
      // `model_response` — treat it as the ModelInvoked analogue.
      return {
        type: "model_invoked",
        model: String(ev.model ?? ""),
        usage: ev.usage as BridgeUsage | undefined,
      };
    case "stream_chunk":
      return {
        type: "stream_chunk",
        raw: String(ev.raw ?? ""),
        kind: ev.kind === "reasoning" ? "reasoning" : "text",
      };
    case "custom":
      return {
        type: "custom",
        source: String(ev.source ?? ""),
        label: String(ev.label ?? ""),
        data: ev.data,
      };
    default:
      return null;
  }
}
