///|
/// Rewind uses physical JSONL line indexes, not parsed message positions.
/// This preserves cetas-js semantics when persisted history contains
/// malformed/blank/synthetic records.
fn rewind_error(message : String) -> Json {
  Json::object(Map::from_array([("error", Json::string(message))]))
}

///|
pub async fn ConsoleRuntime::rewind_points_json(self : ConsoleRuntime) -> Json {
  let workspace = self.active()
  let handle = workspace.active()
  if handle.busy {
    return rewind_error("cannot rewind while a turn is running")
  }
  let path = @fs_session.jsonl_session_path(
    workspace.platform.session_store.root_dir,
    handle.session_id,
  )
  let jsonl = match @fs.read_file(path) {
    data => data.text()
  } catch {
    _ => ""
  }
  let points : Array[Json] = []
  for point in @cetas_core.list_persisted_rewind_points(jsonl) {
    points.push(Json::object(Map::from_array([
      ("message_index", Json::number(point.message_index.to_double())),
      ("preview", Json::string(point.preview)),
    ])))
  }
  Json::object(Map::from_array([("points", Json::array(points))]))
}

///|
/// Rewind persists first, then discards the old Agent and composes a new
/// SessionHandle from the truncated history. Otherwise the old Agent could
/// answer with context that the UI believes was removed.
pub async fn ConsoleRuntime::rewind_active_session(
  self : ConsoleRuntime,
  index : Int32,
) -> Json {
  let workspace = self.active()
  let handle = workspace.active()
  if handle.busy {
    return rewind_error("cannot rewind while a turn is running")
  }
  let path = @fs_session.jsonl_session_path(
    workspace.platform.session_store.root_dir,
    handle.session_id,
  )
  let data = @fs.read_file(path) catch {
    error => return rewind_error("cannot read JSONL: " + error.to_string())
  }
  let text = match @cetas_core.read_persisted_rewind_user_message(
    data.text(),
    index,
  ) {
    Some(value) => value
    None => return rewind_error("invalid rewind address"),
  }
  @cetas_core.rewind_session(
    workspace.platform.session_store as &@posoco.SessionPort,
    handle.session_id,
    index,
  ) catch {
    error => return rewind_error("rewind failed: " + error.to_string())
  }
  handle.agent.shutdown()
  workspace.handles.remove(handle.session_id)
  let restored = self.compose_handle(workspace, handle.session_id)
  match restored {
    Err(detail) => return rewind_error("rewind applied but session recompose failed: " + detail)
    Ok(next) => emit_workspace_snapshot(workspace, next)
  }
  Json::object(Map::from_array([
    ("text", Json::string(text)),
    ("message_index", Json::number(index.to_double())),
    ("session_id", Json::string(handle.session_id)),
  ]))
}
