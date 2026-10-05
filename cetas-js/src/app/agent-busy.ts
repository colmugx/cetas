/**
 * Structured Busy contract for the legacy raw `cetas_js_run_turn` boundary.
 *
 * Core rejects a second admission with `AgentError::Busy(operation_id,
 * session)`; the MoonBit `from_async` boundary would stringify that into a
 * human error string and erase the operation identity. Instead the lib
 * RESOLVES this discriminated JSON envelope and still rejects with every
 * other (non-Busy) provider error, so hosts parse one fixed shape and never
 * match on error text.
 *
 * LEGACY ONLY: this marker rides the same string as raw transcript bytes, so
 * a legitimate assistant reply that happens to be this exact JSON is
 * indistinguishable from a Busy admission loss. Production hosts must use the
 * dedicated `cetas_js_run_turn_result` export (`decodeAgentRunTurnResult`
 * below), whose envelope carries the discriminator structurally. This parser
 * stays for hosts still bound to the raw export.
 */

export interface AgentBusyWire {
  readonly posoco_busy: true;
  readonly operation_id: string;
  readonly session: string;
}

/**
 * Parse one legacy raw export resolution into its structured Busy envelope,
 * or `undefined` when the bytes are the transcript (any non-envelope string,
 * JSON included, passes through untouched).
 */
export function parseAgentBusyWire(text: string): AgentBusyWire | undefined {
  if (!text.startsWith("{")) return undefined;
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  if (record.posoco_busy !== true) return undefined;
  const operationId = record.operation_id;
  const session = record.session;
  if (typeof operationId !== "string" || operationId.length === 0) return undefined;
  if (typeof session !== "string" || session.length === 0) return undefined;
  return { posoco_busy: true, operation_id: operationId, session };
}

/**
 * Structurally discriminated run-turn result wire for the dedicated
 * `cetas_js_run_turn_result` export. `kind` is the only discriminator and it
 * lives on the envelope — never on transcript bytes — so a legitimate
 * assistant JSON reply can never be misread as a Busy admission loss (the
 * legacy raw wire's ambiguity). The transcript rides inside the envelope as a
 * JSON string, so the host decodes the envelope exactly once and never
 * re-parses assistant output.
 */
export type AgentRunTurnResultWire =
  | { readonly kind: "transcript"; readonly transcript: string }
  | {
      readonly kind: "busy";
      readonly operation_id: string;
      readonly session: string;
    };

/**
 * Decode one `cetas_js_run_turn_result` resolution. The export resolves only
 * this envelope, so any other shape is a bridge/version-skew defect and must
 * throw — never degrade into, or be hidden behind, a transcript.
 */
export function decodeAgentRunTurnResult(text: string): AgentRunTurnResultWire {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("run-turn result must be a JSON envelope");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("run-turn result envelope must be an object");
  }
  const record = value as Record<string, unknown>;
  if (record.kind === "transcript") {
    const transcript = record.transcript;
    if (typeof transcript !== "string") {
      throw new Error("run-turn result envelope.transcript must be a string");
    }
    return { kind: "transcript", transcript };
  }
  if (record.kind === "busy") {
    const operationId = record.operation_id;
    const session = record.session;
    if (typeof operationId !== "string" || operationId.length === 0) {
      throw new Error(
        "run-turn result envelope.operation_id must be a non-empty string",
      );
    }
    if (typeof session !== "string" || session.length === 0) {
      throw new Error(
        "run-turn result envelope.session must be a non-empty string",
      );
    }
    return { kind: "busy", operation_id: operationId, session };
  }
  throw new Error(
    'run-turn result envelope.kind must be "transcript" or "busy"',
  );
}

/**
 * Typed rejection for input that lost core admission. `operation_id` and
 * `session` identify the incumbent operation so the loser can wait for its
 * settled boundary and re-admit without rerunning anything already admitted.
 */
export class AgentBusyError extends Error {
  readonly name = "AgentBusyError";

  constructor(
    readonly operationId: string,
    readonly session: string,
  ) {
    super(`core operation ${operationId} on session ${session} holds the agent`);
  }
}
