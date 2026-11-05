import { parseCoreCustom, type CoreOperationStarted, type CoreOperationSettled } from "../core-events.ts";

/**
 * One queued-message delivery fact (posoco 0.24 `MessageApplied` /
 * `MessageUndelivered`). The application owns the pending-input queue, so it
 * reconciles these receipts against its own entries by `commandId` instead of
 * forwarding every attempt to the renderer.
 */
export interface ObserverDeliveryFact {
  readonly kind: "applied" | "undelivered";
  readonly commandId: string;
  readonly delivery: "step" | "turn";
  readonly reason?: string;
}

/** Minimal lifecycle projection from untrusted observer JSON.
 * The original bytes remain authoritative for renderer diagnostics and forwarding.
 */
export interface ObserverProjection {
  readonly type?: string;
  readonly operation?: CoreOperationStarted | CoreOperationSettled;
  readonly delivery?: ObserverDeliveryFact;
}

export function projectObserverEvent(raw: string): ObserverProjection {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return {};
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  const event = value as Record<string, unknown>;
  const type = typeof event.type === "string" ? event.type : undefined;
  if (type === "message_applied" || type === "message_undelivered") {
    const delivery = projectDeliveryFact(type, event);
    // A malformed delivery fact degrades to a bare type, exactly like an
    // unparsable custom: the application keeps its queue untouched and the
    // renderer's own lenient parser reports the skew.
    return delivery === undefined ? { type } : { type, delivery };
  }
  if (type !== "custom" || typeof event.source !== "string" || typeof event.label !== "string") {
    return { type };
  }
  const parsed = parseCoreCustom(event.source, event.label, event.data);
  return parsed.kind === "operation" ? { type, operation: parsed.event } : { type };
}

function projectDeliveryFact(
  type: "message_applied" | "message_undelivered",
  event: Record<string, unknown>,
): ObserverDeliveryFact | undefined {
  const commandId = event.command_id;
  if (typeof commandId !== "string" || commandId.length === 0) return undefined;
  const delivery = event.delivery;
  if (delivery !== "step" && delivery !== "turn") return undefined;
  if (type === "message_applied") {
    return { kind: "applied", commandId, delivery };
  }
  const reason = event.reason;
  return {
    kind: "undelivered",
    commandId,
    delivery,
    ...(typeof reason === "string" ? { reason } : {}),
  };
}
