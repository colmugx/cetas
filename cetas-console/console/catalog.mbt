///|
/// Host-side seam for everything the UI needs from a session store beyond
/// the kernel's `@port.SessionStore` (load/save/append/checkpoint/truncate).
/// `list/entry/set_name` do not exist on any posoco port yet; until the port
/// grows catalog methods, swapping store implementations means writing one
/// adapter here and nothing else changes.
pub(open) trait SessionCatalog {
  fn check_id(Self, String) -> Result[Unit, String]
  async fn list_ids(Self) -> Array[String]
  async fn entry(Self, String) -> SessionCatalogEntry
  async fn set_name(Self, String, String) -> Unit
  async fn load(Self, String) -> @posoco_types.Session
  /// Native-only replay seam: the absolute path of this session's persisted
  /// transcript, when the implementation has one. The shared web/default
  /// console keeps replaying through `load`; the native host uses this to
  /// stream the JSONL journal in bounded chunks instead of materialising it.
  fn transcript_path(Self, String) -> Result[String, String]
}

///|
/// Implementation-neutral projection; `title` is already display-resolved.
struct SessionCatalogEntry {
  id : String
  title : String
}

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
  { id: summary.id, title: @fs_session.display_title(summary), }
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
