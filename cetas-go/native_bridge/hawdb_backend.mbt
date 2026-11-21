///|
struct HawdbConsoleCatalog {
  store : @hawdb_session.HawdbSessionStore
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn check_id(
  _self,
  session_id : String,
) -> Result[Unit, String] {
  @hawdb_session.HawdbSessionStore::check_id(session_id)
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn list_ids(
  self,
) -> Array[String] raise {
  self.store.list_ids()
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn entry(
  self,
  session_id : String,
) -> @console.SessionCatalogEntry raise {
  let summary = self.store.summary(session_id)
  {
    id: summary.id,
    title: @hawdb_session.hawdb_display_title(summary),
  }
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn set_name(
  self,
  session_id : String,
  name : String,
) -> Unit raise {
  self.store.set_session_name(session_id, name)
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn load(
  self,
  session_id : String,
) -> @posoco.Session raise {
  self.store.load(session_id)
}

///|
impl @console.SessionCatalog for HawdbConsoleCatalog with fn transcript_path(
  _self,
  _session_id : String,
) -> Result[String, String] {
  Err("HawDB session transcripts are stored in the database")
}

///|
fn hawdb_workspace_path(home : String, cwd : String) -> String {
  let mut hash = 14695981039346656037UL
  for byte in @utf8.encode(cwd) {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  home + "/hawdb-session-" + hash.to_string()
}

///|
fn open_hawdb_console_backend(
  home : String,
  cwd : String,
) -> Result[@console.ConsoleSessionBackend, String] {
  let path = hawdb_workspace_path(home, cwd)
  let store = match @hawdb_session.HawdbSessionStore::open(
    path,
    cwd=Some(cwd),
  ) {
    Ok(store) => store
    Err(reason) => return Err(reason)
  }
  let catalog : &@console.SessionCatalog = HawdbConsoleCatalog::{store}
  let extension : &@posoco.Extension = store
  let port : &@posoco.SessionPort = store
  Ok({
    session: { extension, port, },
    catalog,
  })
}
