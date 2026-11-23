/** The wire discriminates on `kind`, never on the assistant's text. */
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
