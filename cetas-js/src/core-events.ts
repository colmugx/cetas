/**
 * core-events.ts — parsers for the frozen core projection Custom schemas
 * (docs/wakeup-decision-development.md "Shared event contract").
 *
 * All four ride the existing `custom` observer event as
 * `{source, label, data}`, so hosts consume them without new bridge
 * signatures. Parsing is strict per the frozen contract: a matched source
 * with a wrong label or a missing/mistyped required field is `malformed`
 * (visible degradation, never guessed into a success), and any other source
 * is `foreign` (existing host behavior unchanged).
 *
 * - posoco.operation: operation_started / operation_settled. started covers
 *   admission through the full follow-up drain and cleanup; settled is the
 *   single authoritative unlock (never TurnCompleted).
 * - posoco.wakeup: one terminal per ticket; executing may carry the
 *   environment envelope.
 * - posoco.tasks: background_outcome_ready, emitted after the outcome is
 *   boxed; never carries the outcome body.
 * - posoco.decision: diagnostics only — call id, attribution, purpose,
 *   declared failure mode; never request/response bodies or raw errors.
 */

export type CoreOperationOrigin = "turn" | "resume" | "compact" | "wakeup";
export type CoreOperationOutcome = "completed" | "failed" | "cancelled";

export interface CoreOperationStarted {
  readonly phase: "started";
  readonly operation_id: string;
  readonly session: string;
  readonly origin: CoreOperationOrigin;
}

export interface CoreOperationSettled {
  readonly phase: "settled";
  readonly operation_id: string;
  readonly session: string;
  readonly origin: CoreOperationOrigin;
  readonly outcome: CoreOperationOutcome;
}

export type CoreWakeupState =
  | "requested"
  | "executing"
  | "satisfied"
  | "completed"
  | "failed"
  | "cancelled"
  | "dropped";

const WAKEUP_STATES: readonly CoreWakeupState[] = [
  "requested",
  "executing",
  "satisfied",
  "completed",
  "failed",
  "cancelled",
  "dropped",
];

export interface CoreWakeupEvent {
  readonly state: CoreWakeupState;
  readonly ticket_id: string;
  readonly session: string;
  readonly tag: string;
  readonly extension_id: string;
  readonly enqueued_at: number;
  readonly operation_id?: string;
  readonly envelope?: string;
}

export type CoreTaskStatus = "completed" | "failed" | "timed_out" | "cancelled";

const TASK_STATUSES: readonly CoreTaskStatus[] = [
  "completed",
  "failed",
  "timed_out",
  "cancelled",
];

export interface CoreTaskReady {
  readonly task_id: string;
  readonly session: string;
  readonly extension_id: string;
  readonly label: string;
  readonly status: CoreTaskStatus;
}

export type CoreDecisionLabel = "started" | "completed" | "failed" | "cancelled";

const DECISION_LABELS: readonly CoreDecisionLabel[] = [
  "started",
  "completed",
  "failed",
  "cancelled",
];

export interface CoreDecisionEvent {
  readonly label: CoreDecisionLabel;
  readonly call_id: string;
  readonly consumer?: string;
  readonly provider?: string;
  readonly purpose?: string;
  readonly failure_mode?: string;
  readonly scope?: string;
  readonly elapsed_ms?: number;
  readonly model?: string;
}

export type CoreCustomParse =
  | { kind: "foreign" }
  | { kind: "malformed"; source: string; reason: string }
  | { kind: "operation"; event: CoreOperationStarted | CoreOperationSettled }
  | { kind: "wakeup"; event: CoreWakeupEvent }
  | { kind: "task"; event: CoreTaskReady }
  | { kind: "decision"; event: CoreDecisionEvent };

type SchemaParse<T> = { ok: true; event: T } | { ok: false; reason: string };

function coreRecord(data: unknown, source: string): Record<string, unknown> {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new Error(`${source} data must be an object`);
  }
  return data as Record<string, unknown>;
}

function requiredString(
  record: Record<string, unknown>,
  key: string,
  source: string,
): string {
  const value = record[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${source} data.${key} must be a non-empty string`);
  }
  return value;
}

function optionalString(
  record: Record<string, unknown>,
  key: string,
  source: string,
): string | undefined {
  const value = record[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") {
    throw new Error(`${source} data.${key} must be a string`);
  }
  return value;
}

function optionalNumber(
  record: Record<string, unknown>,
  key: string,
  source: string,
): number | undefined {
  const value = record[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${source} data.${key} must be a number`);
  }
  return value;
}

function requiredOneOf<T extends string>(
  record: Record<string, unknown>,
  key: string,
  allowed: readonly T[],
  source: string,
): T {
  const value = record[key];
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new Error(
      `${source} data.${key} must be one of ${allowed.map((a) => `"${a}"`).join(" | ")}`,
    );
  }
  return value as T;
}

function parseOperationCustom(
  label: string,
  data: unknown,
): SchemaParse<CoreOperationStarted | CoreOperationSettled> {
  const source = "posoco.operation";
  if (label !== "operation_started" && label !== "operation_settled") {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  try {
    const record = coreRecord(data, source);
    const operation_id = requiredString(record, "operation_id", source);
    const session = requiredString(record, "session", source);
    const origin = requiredOneOf(
      record,
      "origin",
      ["turn", "resume", "compact", "wakeup"] as const,
      source,
    );
    if (label === "operation_started") {
      return {
        ok: true,
        event: { phase: "started", operation_id, session, origin },
      };
    }
    const outcome = requiredOneOf(
      record,
      "outcome",
      ["completed", "failed", "cancelled"] as const,
      source,
    );
    return {
      ok: true,
      event: { phase: "settled", operation_id, session, origin, outcome },
    };
  } catch (error: unknown) {
    return { ok: false, reason: errorMessage(error) };
  }
}

function parseWakeupCustom(
  label: string,
  data: unknown,
): SchemaParse<CoreWakeupEvent> {
  const source = "posoco.wakeup";
  if (!label.startsWith("wakeup_")) {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  const state = label.slice("wakeup_".length);
  if (!WAKEUP_STATES.includes(state as CoreWakeupState)) {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  try {
    const record = coreRecord(data, source);
    return {
      ok: true,
      event: {
        state: state as CoreWakeupState,
        ticket_id: requiredString(record, "ticket_id", source),
        session: requiredString(record, "session", source),
        tag: requiredString(record, "tag", source),
        extension_id: requiredString(record, "extension_id", source),
        enqueued_at: optionalNumber(record, "ticket_enqueued_at", source) ?? 0,
        operation_id: optionalString(record, "operation_id", source),
        envelope: optionalString(record, "envelope", source),
      },
    };
  } catch (error: unknown) {
    return { ok: false, reason: errorMessage(error) };
  }
}

function parseTaskCustom(label: string, data: unknown): SchemaParse<CoreTaskReady> {
  const source = "posoco.tasks";
  if (label !== "background_outcome_ready") {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  try {
    const record = coreRecord(data, source);
    return {
      ok: true,
      event: {
        task_id: requiredString(record, "task_id", source),
        session: requiredString(record, "session", source),
        extension_id: requiredString(record, "extension_id", source),
        label: requiredString(record, "label", source),
        status: requiredOneOf(record, "status", TASK_STATUSES, source),
      },
    };
  } catch (error: unknown) {
    return { ok: false, reason: errorMessage(error) };
  }
}

function parseDecisionCustom(
  label: string,
  data: unknown,
): SchemaParse<CoreDecisionEvent> {
  const source = "posoco.decision";
  if (!label.startsWith("decision_")) {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  const name = label.slice("decision_".length);
  if (!DECISION_LABELS.includes(name as CoreDecisionLabel)) {
    return { ok: false, reason: `${source} label "${label}" is unsupported` };
  }
  try {
    const record = coreRecord(data, source);
    return {
      ok: true,
      event: {
        label: name as CoreDecisionLabel,
        call_id: requiredString(record, "call_id", source),
        consumer: optionalString(record, "consumer", source),
        provider: optionalString(record, "provider", source),
        purpose: optionalString(record, "purpose", source),
        failure_mode: optionalString(record, "failure_mode", source),
        scope: optionalString(record, "scope", source),
        elapsed_ms: optionalNumber(record, "elapsed_ms", source),
        model: optionalString(record, "model", source),
      },
    };
  } catch (error: unknown) {
    return { ok: false, reason: errorMessage(error) };
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Classify one `custom` observer event against the frozen core schemas. */
export function parseCoreCustom(
  source: string,
  label: string,
  data: unknown,
): CoreCustomParse {
  switch (source) {
    case "posoco.operation": {
      const parsed = parseOperationCustom(label, data);
      return parsed.ok
        ? { kind: "operation", event: parsed.event }
        : { kind: "malformed", source, reason: parsed.reason };
    }
    case "posoco.wakeup": {
      const parsed = parseWakeupCustom(label, data);
      return parsed.ok
        ? { kind: "wakeup", event: parsed.event }
        : { kind: "malformed", source, reason: parsed.reason };
    }
    case "posoco.tasks": {
      const parsed = parseTaskCustom(label, data);
      return parsed.ok
        ? { kind: "task", event: parsed.event }
        : { kind: "malformed", source, reason: parsed.reason };
    }
    case "posoco.decision": {
      const parsed = parseDecisionCustom(label, data);
      return parsed.ok
        ? { kind: "decision", event: parsed.event }
        : { kind: "malformed", source, reason: parsed.reason };
    }
    default:
      return { kind: "foreign" };
  }
}

/**
 * Bounded single-line diagnostic attribution for a failed decision call.
 * Reads only schema fields — never payload bodies — and omits absent parts.
 */
export function decisionFailureDiagnostic(event: CoreDecisionEvent): string {
  const parts: string[] = [];
  const route =
    event.consumer !== undefined || event.provider !== undefined
      ? [event.consumer ?? "?", event.provider ?? "?"].join("→")
      : undefined;
  if (route !== undefined) parts.push(route);
  if (event.purpose !== undefined) parts.push(`purpose ${event.purpose}`);
  if (event.failure_mode !== undefined) parts.push(`mode ${event.failure_mode}`);
  return parts.length === 0 ? event.call_id : parts.join(" · ");
}
