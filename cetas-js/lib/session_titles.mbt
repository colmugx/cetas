///|
/// session_titles.mbt — host-facing session facts for the /sessions picker.
/// The bucket formula and the title rules live in posoco-ext-fs-session;
/// cetas-js only projects them over the JS boundary so TypeScript never
/// re-derives directory names or first-message titles.

///|
/// Resolved per-project session bucket for (home, cwd) — the same directory
/// the config constructor falls back to for an empty `sessions_dir`. Pure
/// string computation, safe before any Agent exists.
pub fn cetas_js_sessions_dir(home : String, cwd : String) -> String {
  @fs_session.project_sessions_dir(home, cwd)
}

///|
/// Titles for every persisted session in one bucket directory as a JSON
/// array string: `[{"id":...,"title":...}]`, where title is fs-session's
/// display_title (metadata name ?? first user message prefix ?? id). A
/// missing directory yields `[]`; a session that fails to load is skipped so
/// one corrupt transcript never blanks the picker.
pub fn cetas_js_session_titles(
  sessions_dir : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    session_titles_json(@fs_session.JsonlSessionStore(sessions_dir))
  }
}

///|
async fn session_titles_json(
  store : @fs_session.JsonlSessionStore,
) -> String raise @posoco.SessionError {
  let entries : Array[Json] = []
  for id in store.list_ids() {
    let loaded : Result[@fs_session.SessionSummary, @posoco.SessionError] = Ok(
      store.summary(id),
    ) catch {
      error => Err(error)
    }
    match loaded {
      Ok(summary) =>
        entries.push(
          Json::object(
            Map::from_array([
              ("id", Json::string(id)),
              ("title", Json::string(@fs_session.display_title(summary))),
            ]),
          ),
        )
      Err(_) => ()
    }
  }
  Json::array(entries).stringify()
}
