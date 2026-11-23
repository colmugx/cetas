///|
pub using @extra_session {trait SessionCatalog, type SessionCatalogEntry}

///|
/// Adapter over the compiled-in fs-session store.
priv struct FsSessionCatalog {
  store : @fs_session.JsonlSessionStore
}

///|
fn FsSessionCatalog::new(
  store : @fs_session.JsonlSessionStore,
) -> FsSessionCatalog {
  { store, }
}

///|
impl SessionCatalog for FsSessionCatalog with fn check_id(
  _self,
  session_id : String,
) -> Result[Unit, String] {
  @fs_session.validate_session_id(session_id)
}

///|
impl SessionCatalog for FsSessionCatalog with fn list_ids(self) -> Array[String] raise {
  self.store.list_ids()
}

///|
impl SessionCatalog for FsSessionCatalog with fn entry(
  self,
  session_id : String,
) -> SessionCatalogEntry raise {
  let summary = self.store.summary(session_id)
  {
    id: summary.id,
    title: @fs_session.display_title(summary),
    cwd: summary.cwd,
  }
}

///|
impl SessionCatalog for FsSessionCatalog with fn set_name(
  self,
  session_id : String,
  name : String,
) -> Unit raise {
  self.store.set_session_name(session_id, name)
}

///|
impl SessionCatalog for FsSessionCatalog with fn load(self, session_id : String) -> @posoco_types.Session raise {
  self.store.load(session_id)
}

///|
impl SessionCatalog for FsSessionCatalog with fn transcript_path(
  self,
  session_id : String,
) -> Result[String, String] {
  match @fs_session.validate_session_id(session_id) {
    Err(reason) => Err(reason)
    Ok(_) => Ok(@fs_session.jsonl_session_path(self.store.root_dir, session_id))
  }
}
