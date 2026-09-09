/**
 * Session identity helpers for cetas-js.
 *
 * The id charset is `0-9A-Za-z-_.` (ISO `:`/`.` replaced by `-`, plus a UUID
 * slice), so ids pass posoco-ext-fs-session's `validate_session_id` (non-empty,
 * no path separators) without widening that check; the directory lives in the
 * store's root_dir, not the id. The UTC timestamp keeps lexicographic order
 * equal to chronological order.
 *
 * The per-project sessions directory is owned by the MoonBit side
 * (`cetas_js_sessions_dir`); TypeScript never re-derives the bucket name.
 */

export function newSessionId(): string {
  return (
    new Date().toISOString().replace(/[:.]/g, "-") +
    "_" +
    crypto.randomUUID().slice(0, 8)
  );
}

/** Transcript path for a session id inside a sessions directory. */
export function sessionFilePath(sessionsDir: string, sessionId: string): string {
  return `${sessionsDir}/${sessionId}.jsonl`;
}
