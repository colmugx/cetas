///|
fn native_database_catalog_json(
  backend : ConsoleSessionBackend,
  cwd : String,
  active_id : String,
  scope : String,
  after : String,
  limit : Int32,
) -> Json {
  let mode = match native_session_catalog_scope(scope) {
    Ok(value) => value
    Err(reason) => return native_session_catalog_error(scope, cwd, reason)
  }
  let entries = (backend.entries)() catch {
    error => return native_session_catalog_error(mode, cwd, error.to_string())
  }
  let normalized = @fs_session.normalize_cwd(cwd)
  let entries = if mode == "current" {
    entries.filter(entry => entry.cwd == Some(normalized))
  } else {
    entries
  }
  let mut start = 0
  if !after.is_empty() {
    while start < entries.length() && entries[start].id != after {
      start += 1
    }
    if start == entries.length() {
      return native_session_catalog_error(
        mode, cwd, "invalid session catalog cursor",
      )
    }
    start += 1
  }
  let cap = if limit <= 0 { 100 } else if limit > 200 { 200 } else { limit }
  let items : Array[Json] = []
  let mut next : Json = Json::null()
  let mut wire_bytes = 128 * 1024
  for n in start..<entries.length() {
    let entry = entries[n]
    let folder = entry.cwd.filter(path => {
      path.length() <= NATIVE_SESSION_CATALOG_MAX_CWD_CHARS
    })
    let fields = Map::from_array([
      ("id", Json::string(entry.id)),
      ("bucket", Json::string("hawdb")),
      (
        "title",
        Json::string(
          native_session_catalog_clip(
            entry.title,
            NATIVE_SESSION_CATALOG_MAX_TITLE_CHARS,
          ),
        ),
      ),
      (
        "cwd",
        match folder {
          Some(path) => Json::string(path)
          None => Json::null()
        },
      ),
      (
        "folder",
        Json::string(
          match folder {
            Some(path) =>
              @fs_session.bucket_slug(@fs_session.project_dir_name(path))
            None => ""
          },
        ),
      ),
      ("sizeBytes", Json::null()),
      ("modifiedAt", Json::null()),
      ("current", Json::boolean(entry.id == active_id)),
      ("resumable", Json::boolean(folder is Some(_))),
    ])
    if folder is None {
      fields["reason"] = Json::string("no usable project folder recorded")
    }
    let row = Json::object(fields)
    let bytes = @utf8.encode(row.stringify()).length()
    if items.length() >= cap || wire_bytes + bytes + 1 > 1024 * 1024 {
      if !items.is_empty() {
        next = Json::string(entries[n - 1].id)
      }
      break
    }
    items.push(row)
    wire_bytes += bytes + 1
  }
  Json::object({
    "scope": Json::string(mode),
    "cwd": Json::string(cwd),
    "items": Json::array(items),
    "next": next,
    "total": Json::number(entries.length().to_double()),
  })
}
