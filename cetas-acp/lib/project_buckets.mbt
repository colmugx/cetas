///|
/// project_buckets.mbt — per-project session storage. Every cwd owns a
/// bucket directory under `<home>/.cetas/sessions` named by ext-fs-session
/// (`session_<slug>_<sha256(cwd)[0..12]>`), so sibling worktrees never share
/// a session list. The host caches one store per bucket, and the sidecar
/// lives beside the history inside the bucket.

///|
/// The cached store for one cwd's bucket, minting (and caching) it on first
/// use. Shared by the production spawn closure and `store_for_cwd` so a
/// session's store and the host's bucket view are always the same instance.
fn cached_project_store(
  stores : Map[String, @fs_session.JsonlSessionStore],
  home~ : String,
  cwd~ : String,
) -> @fs_session.JsonlSessionStore {
  let key = @fs_session.project_dir_name(cwd)
  match stores.get(key) {
    Some(store) => store
    None => {
      let store = @fs_session.JsonlSessionStore::of_project(home~, cwd~)
      stores[key] = store
      store
    }
  }
}

///|
/// The project store for one cwd (the process cwd when empty), resolving
/// through the host's per-bucket cache.
fn CetasAcpHost::store_for_cwd(
  self : CetasAcpHost,
  cwd : String,
) -> @fs_session.JsonlSessionStore {
  let resolved = if cwd.length() > 0 { cwd } else { self.process_cwd }
  cached_project_store(self.stores, home=self.home, cwd=resolved)
}

///|
/// A session's sidecar sits inside its project bucket:
/// `<project_dir>/<session_id>.host.json`. Invalid ids have no safe file
/// stem, hence no sidecar path at all.
fn host_sidecar_path(project_dir : String, session_id : String) -> String? {
  match @fs_session.validate_session_id(session_id) {
    Ok(_) => Some(@fs_session.companion_path(project_dir, session_id))
    Err(_) => None
  }
}

///|
/// Every project bucket a persisted session may live in, most specific
/// first: the client cwd's bucket, the buckets of this process's cached
/// stores, the host's default store root, and the bucket directories
/// enumerated on disk (sessions from earlier runs and other processes).
async fn CetasAcpHost::candidate_project_dirs(
  self : CetasAcpHost,
  client_cwd? : String = "",
) -> Array[String] noraise {
  let dirs : Array[String] = []
  let seen : Map[String, Bool] = Map::from_array([])
  // Insertion-ordered dedup: the most specific bucket answers first.
  fn push_unique(dir : String) -> Unit {
    if !seen.contains(dir) {
      seen[dir] = true
      dirs.push(dir)
    }
  }
  if client_cwd.length() > 0 {
    push_unique(@fs_session.project_sessions_dir(self.home, client_cwd))
  }
  for _key, store in self.stores {
    push_unique(store.root_dir)
  }
  push_unique(self.session_store.root_dir)
  let root = @cetas_core.sessions_dir(self.home)
  let entries : Array[String] = self.fs.readdir(root, include_hidden=false) catch {
    _ => []
  }
  for entry in entries {
    if entry.has_prefix("session_") {
      push_unique(root + "/" + entry)
    }
  }
  dirs
}

///|
/// `session/list`: bucket-scoped. With a `cwd` param the answer is exactly
/// that project's bucket — the bucket is the isolation, so the old
/// list-then-filter-by-cwd pass is gone. Without one, every candidate bucket
/// is enumerated and only sessions carrying a sidecar are reported (their
/// sidecar records the cwd). One page: the incoming cursor is ignored and
/// `next_cursor` omitted — clients read that as the end of the list.
pub async fn CetasAcpHost::handle_list_sessions(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.ListSessionsParams,
) -> @acp.ListSessionsResult raise @acp.HandlerError {
  self.debug_wire_in(
    session_id="host",
    rpc_method="session/list",
    params=debug_list_params(params),
  )
  let sessions : Array[@acp.SessionInfo] = []
  match params.cwd {
    Value(want) => {
      let store = self.store_for_cwd(want)
      let listed : Result[Array[String], Error] = Ok(store.list_ids()) catch {
        error => Err(error)
      }
      let ids = match listed {
        Ok(ids) => ids
        Err(error) =>
          raise @acp.HandlerError::Application(
            message="cetas-acp: session list failed: " + error.to_string(),
          )
      }
      for id in ids {
        let titled : Result[String, Error] = Ok(
          @fs_session.display_title(store.summary(id)),
        ) catch {
          error => Err(error)
        }
        let title = match titled {
          Ok(title) => title
          Err(_) => id
        }
        // The answer reports the sidecar's own cwd, never a blind echo of the
        // request; an entry whose sidecar records another project's cwd (a
        // drifted restore) does not belong in this bucket's answer.
        let sidecar = read_session_sidecar(
          self.fs,
          project_dir=store.root_dir,
          session_id=id,
        )
        let recorded : String? = match sidecar {
          Some({ cwd, .. }) => if cwd.length() > 0 { Some(cwd) } else { None }
          None => None
        }
        let mut drifted = false
        let cwd = match recorded {
          Some(real) => {
            if @fs_session.normalize_cwd(real) !=
              @fs_session.normalize_cwd(want) {
              drifted = true
            }
            real
          }
          None => want
        }
        if drifted {
          continue
        }
        sessions.push({
          session_id: id,
          cwd,
          additional_directories: Omitted,
          title: Value(title),
          updated_at: session_updated_at(project_dir=store.root_dir, id~),
          meta: Omitted,
        })
      }
    }
    _ =>
      for dir in self.candidate_project_dirs() {
        let bucket = @fs_session.JsonlSessionStore(dir)
        let listed : Result[Array[String], Error] = Ok(bucket.list_ids()) catch {
          error => Err(error)
        }
        let ids = match listed {
          Ok(ids) => ids
          Err(_) => []
        }
        for id in ids {
          // No sidecar means this host never drove the session — skip it.
          let sidecar = read_session_sidecar(
            self.fs,
            project_dir=dir,
            session_id=id,
          )
          match sidecar {
            None => ()
            Some({ cwd, .. }) => {
              let titled : Result[String, Error] = Ok(
                @fs_session.display_title(bucket.summary(id)),
              ) catch {
                error => Err(error)
              }
              let title = match titled {
                Ok(title) => title
                Err(_) => id
              }
              sessions.push({
                session_id: id,
                cwd: if cwd.length() > 0 {
                  cwd
                } else {
                  self.process_cwd
                },
                additional_directories: Omitted,
                title: Value(title),
                updated_at: session_updated_at(project_dir=dir, id~),
                meta: Omitted,
              })
            }
          }
        }
      }
  }
  { sessions, next_cursor: Omitted, meta: Omitted, }
}

///|
/// Best-effort `updated_at` for a listed session: the history file's mtime
/// rendered as an RFC 3339 UTC timestamp; an unstatable file omits the
/// field. The host fs seam carries no stat, so this reads the real fs.
async fn session_updated_at(
  project_dir~ : String,
  id~ : String,
) -> @acp.ProtocolNullable[String] noraise {
  let stamped : Result[(Int64, Int), Error] = Ok(
    @fs.mtime(@fs_session.jsonl_session_path(project_dir, id)),
  ) catch {
    error => Err(error)
  }
  match stamped {
    Ok((seconds, _)) => Value(iso8601_utc(seconds))
    Err(_) => Omitted
  }
}

///|
/// RFC 3339 UTC rendering of epoch seconds (`2026-09-08T12:34:56Z`); the
/// y/m/d conversion is the standard civil-from-days algorithm.
fn iso8601_utc(epoch_seconds : Int64) -> String {
  let mut days = epoch_seconds / 86_400L
  let rem = epoch_seconds % 86_400L
  let mut seconds_of_day = rem
  if rem < 0L {
    seconds_of_day = rem + 86_400L
    days -= 1L
  }
  let z = days + 719_468L
  let era = (if z >= 0L { z } else { z - 146_096L }) / 146_097L
  let doe = z - era * 146_097L
  let yoe = (doe - doe / 1_460L + doe / 36_524L - doe / 146_096L) / 365L
  let year_of_era = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if month <= 2L { year_of_era + 1L } else { year_of_era }
  let mut year_text = year.to_string()
  while year_text.length() < 4 {
    year_text = "0" + year_text
  }
  "\{year_text}-\{pad2(month)}-\{pad2(day)}T\{pad2(seconds_of_day / 3_600L)}:\{pad2((seconds_of_day % 3_600L) / 60L)}:\{pad2(seconds_of_day % 60L)}Z"
}

///|
fn pad2(value : Int64) -> String {
  if value < 10L {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}
