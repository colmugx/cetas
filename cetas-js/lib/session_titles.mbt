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
/// Every persisted session of every project bucket under
/// `project_sessions_root(home)`, as a JSON array string of
/// `{"id","title","bucket","dir","folder","cwd"}`:
/// `bucket` is the bucket directory name, `dir` its full path, `folder` the
/// slug recovered from that name (the display fallback), and `cwd` the
/// directory recorded in the session metadata — `null` for journals written
/// before that contract, which stay visible but not cross-resumable.
///
/// The bucket walk stays here (next to the formula) so the host's "All" view
/// never re-implements `session_<slug>_<hash>`. A missing root is `[]`; an
/// unreadable bucket or session is skipped, exactly like the per-bucket list.
pub fn cetas_js_session_catalog(home : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => { session_catalog_json(home) }
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

///|
async fn session_catalog_json(home : String) -> String {
  let fs : &@workspace.WorkspaceFs = @workspace.JsWorkspaceFs()
  let root = @fs_session.project_sessions_root(home)
  let entries : Array[Json] = []
  // A missing sessions root (first run) is an empty catalog, not an error.
  let names : Array[String] = fs.readdir(root, include_hidden=false) catch {
    _ => []
  }
  for name in names {
    if !@fs_session.is_project_dir_name(name) {
      continue
    }
    let dir = root + "/" + name
    let kind : @workspace.WorkspaceFileKind = fs.kind(dir, follow_symlink=false) catch {
      _ => continue
    }
    match kind {
      @workspace.Dir => ()
      _ => continue
    }
    let store = @fs_session.JsonlSessionStore(dir)
    let ids = store.list_ids() catch { _ => continue }
    for id in ids {
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
                ("bucket", Json::string(name)),
                ("dir", Json::string(dir)),
                ("folder", Json::string(@fs_session.bucket_slug(name))),
                (
                  "cwd",
                  match summary.cwd {
                    Some(cwd) => Json::string(cwd)
                    None => Json::null()
                  },
                ),
              ]),
            ),
          )
        Err(_) => ()
      }
    }
  }
  Json::array(entries).stringify()
}
