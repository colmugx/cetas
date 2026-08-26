/**
 * Session identity and per-project sessions directory, mirroring pi's layout:
 * `<home>/.cetas/sessions/--<encoded-cwd>--/<UTC timestamp>_<8 hex>.jsonl`.
 *
 * The id charset is `0-9A-Za-z-_.` (ISO `:`/`.` replaced by `-`, plus a UUID
 * slice), so ids pass posoco-ext-fs-session's `validate_session_id` (non-empty,
 * no path separators) without widening that check; the directory lives in the
 * store's root_dir, not the id. The UTC timestamp keeps lexicographic order
 * equal to chronological order.
 */

export function newSessionId(): string {
  return (
    new Date().toISOString().replace(/[:.]/g, "-") +
    "_" +
    crypto.randomUUID().slice(0, 8)
  );
}

export function projectSessionsDir(home: string, cwd: string): string {
  return `${home}/.cetas/sessions/--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
}

/** Transcript path for a session id inside a sessions directory. */
export function sessionFilePath(sessionsDir: string, sessionId: string): string {
  return `${sessionsDir}/${sessionId}.jsonl`;
}
