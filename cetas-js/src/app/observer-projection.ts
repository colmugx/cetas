import { parseCoreCustom, type CoreOperationStarted, type CoreOperationSettled } from "../core-events.ts";

/** Minimal lifecycle projection from untrusted observer JSON.
 * The original bytes remain authoritative for renderer diagnostics and forwarding.
 */
export interface ObserverProjection {
  readonly type?: string;
  readonly operation?: CoreOperationStarted | CoreOperationSettled;
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
  if (type !== "custom" || typeof event.source !== "string" || typeof event.label !== "string") {
    return { type };
  }
  const parsed = parseCoreCustom(event.source, event.label, event.data);
  return parsed.kind === "operation" ? { type, operation: parsed.event } : { type };
}
