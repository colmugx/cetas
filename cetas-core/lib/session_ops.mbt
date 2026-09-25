/// Target-agnostic persisted-session operations shared by Cetas hosts.

///|
/// Rewind a persisted session by dropping messages at `from_index` and after.
///
/// The SessionStore contract owns the exact semantics: `from_index` is
/// clamped to the current message bounds, metadata is preserved, and backend
/// failures retain their typed SessionError variant. Hosts should keep policy
/// guards (for example "not while a turn is running") outside this helper.
pub async fn rewind_session(
  store : &@posoco.SessionStore,
  session_id : String,
  from_index : Int,
) -> Unit raise @posoco.SessionError {
  store.truncate(session_id, from_index)
}
