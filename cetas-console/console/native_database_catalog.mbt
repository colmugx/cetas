///|
async fn native_database_catalog_json(
  runtime : ConsoleRuntime,
  scope : String,
  after : String,
  limit : Int32,
) -> Json {
  let mode = if scope.is_empty() || scope == "default" {
    "current"
  } else {
    scope
  }
  if mode != "current" {
    return native_session_catalog_error(
      scope,
      runtime.active_cwd,
      "database catalog currently requires the current workspace",
    )
  }
  let workspace = runtime.active()
  let ids = workspace.catalog.list_ids() catch {
    error =>
      return native_session_catalog_error(
        mode,
        workspace.cwd,
        error.to_string(),
      )
  }
  let requested = if limit <= 0 { 100 } else { limit }
  let cap = if requested > 200 { 200 } else { requested }
  let items : Array[Json] = []
  let mut collecting = after.is_empty()
  let mut matched_cursor = after.is_empty()
  let mut next : Json = Json::null()
  let mut wire_bytes = 128 * 1024
  for n in 0..<ids.length() {
    let id = ids[ids.length() - 1 - n]
    if !collecting {
      if id == after {
        collecting = true
        matched_cursor = true
      }
      continue
    }
    let entry = workspace.catalog.entry(id) catch {
      error =>
        return native_session_catalog_error(
          mode,
          workspace.cwd,
          error.to_string(),
        )
    }
    let title = native_session_catalog_clip(entry.title, 200)
    let row = Json::object({
      "id": Json::string(id),
      "bucket": Json::string("hawdb"),
      "title": Json::string(title),
      "cwd": Json::string(workspace.cwd),
      "folder": Json::string(workspace.cwd),
      "sizeBytes": Json::null(),
      "modifiedAt": Json::null(),
      "current": Json::boolean(id == workspace.active_id),
      "resumable": Json::boolean(true),
    })
    let bytes = @utf8.encode(row.stringify()).length()
    if items.length() >= cap || wire_bytes + bytes + 1 > 1024 * 1024 {
      if !items.is_empty() {
        next = Json::string(ids[ids.length() - n])
      }
      break
    }
    items.push(row)
    wire_bytes += bytes + 1
  }
  if !matched_cursor {
    return native_session_catalog_error(
      mode,
      workspace.cwd,
      "invalid session catalog cursor",
    )
  }
  Json::object({
    "scope": Json::string(mode),
    "cwd": Json::string(workspace.cwd),
    "items": Json::array(items),
    "next": next,
    "total": Json::number(ids.length().to_double()),
  })
}
