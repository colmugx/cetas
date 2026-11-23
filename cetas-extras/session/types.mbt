///|
/// Session metadata and transcript access used by the console UI.
pub(open) trait SessionCatalog {
  fn check_id(Self, String) -> Result[Unit, String]
  async fn list_ids(Self) -> Array[String]
  async fn entry(Self, String) -> SessionCatalogEntry
  async fn set_name(Self, String, String) -> Unit
  async fn load(Self, String) -> @posoco.Session
  /// Native-only replay seam: the absolute path of this session's persisted
  /// transcript, when the implementation has one. The shared web/default
  /// console keeps replaying through `load`; the native host uses this to
  /// stream the JSONL journal in bounded chunks instead of materialising it.
  fn transcript_path(Self, String) -> Result[String, String]
}

///|
/// Implementation-neutral projection; `title` is already display-resolved.
pub(all) struct SessionCatalogEntry {
  id : String
  title : String
  cwd : String?
}

///|
pub(all) struct ConsoleSessionBackend {
  session : (String, String) -> @cetas_core.CetasSessionBackend
  catalog : &SessionCatalog
  entries : () -> Array[SessionCatalogEntry] raise
  revision : (String) -> Result[String, String]
  close : () -> Unit
}
