///|
/// K2: a switch that activates a session handle must re-emit that handle's
/// current statusbar registry. The host retires its presentation on
/// `session.switched` and rebuilds the strip from the snapshot fallback
/// fields alone, so without a fresh render the per-session segments
/// (ctx/mcp/quota/...) stay gone until the next unrelated segment op.

///|
/// The entries of the last `ui.render` frame whose `key` is "statusbar" and
/// which is attributed to `session_id`, scanned from index `from` on.
/// Returns the frame index together with the entries so ordering assertions
/// can compare it against the snapshot frame.
fn switch_statusbar_render(
  frames : Array[String],
  session_id : String,
  from : Int32,
) -> (Int32, Array[Json])? {
  let mut found : (Int32, Array[Json])? = None
  for index in from..<frames.length() {
    let parsed = @json.parse(frames[index]) catch { _ => continue }
    let fields = match parsed {
      Json::Object(fields) => fields
      _ => continue
    }
    let attributed = match fields.get("session_id") {
      Some(Json::String(id)) => id == session_id
      _ => false
    }
    let is_render = match fields.get("type") {
      Some(Json::String("ui.render")) => true
      _ => false
    }
    let is_bar = match fields.get("key") {
      Some(Json::String("statusbar")) => true
      _ => false
    }
    if attributed && is_render && is_bar {
      let entries = match fields.get("entries") {
        Some(Json::Array(entries)) => entries
        _ => []
      }
      found = Some((index, entries))
    }
  }
  found
}

///|
/// Index of the last `session.snapshot` frame attributed to `session_id`
/// scanned from `from` on; -1 when none arrived.
fn switch_last_snapshot_index(
  frames : Array[String],
  session_id : String,
  from : Int32,
) -> Int32 {
  let mut found = -1
  for index in from..<frames.length() {
    let parsed = @json.parse(frames[index]) catch { _ => continue }
    let fields = match parsed {
      Json::Object(fields) => fields
      _ => continue
    }
    let attributed = match fields.get("session_id") {
      Some(Json::String(id)) => id == session_id
      _ => false
    }
    let is_snapshot = match fields.get("type") {
      Some(Json::String("session.snapshot")) => true
      _ => false
    }
    if attributed && is_snapshot {
      found = index
    }
  }
  found
}

///|
/// The entries as a key -> value map, the shape the host bar mounts.
fn switch_entries_map(entries : Array[Json]) -> Map[String, String] {
  let map : Map[String, String] = Map::from_array([])
  for entry in entries {
    match entry {
      Json::Object(fields) =>
        match (fields.get("key"), fields.get("value")) {
          (Some(Json::String(key)), Some(Json::String(value))) =>
            map[key] = value
          _ => ()
        }
      _ => ()
    }
  }
  map
}

///|
/// A switch to a handle that is already composed must re-emit that handle's
/// current registry — in each direction, and after the snapshot.
async test "switching between cached handles re-emits each statusbar registry" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-switch-bar-")
    let (runtime, frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
    )
    let first = runtime.active_session_id()
    let workspace = runtime.active()
    let first_handle = workspace.active()
    // One distinct segment per session, registered the way a peer
    // extension's op lands in the bar.
    first_handle.statusbar.set_segment(
      source="cetas-wb-k2",
      segment="wb-first",
      value="one",
    )
    // Compose a second handle without activating it: the later switch then
    // exercises exactly the cached-handle path, in both directions.
    let second = "cetas-17943001000"
    let second_handle = permission_ok(runtime.compose_handle(workspace, second))
    second_handle.statusbar.set_segment(
      source="cetas-wb-k2",
      segment="wb-second",
      value="two",
    )
    let before = frames.length()
    match runtime.switch_session(second) {
      Ok(_) => ()
      Err(reason) => fail("switch to second session failed: " + reason)
    }
    match switch_statusbar_render(frames, second, before) {
      Some((render_at, entries)) => {
        let bar = switch_entries_map(entries)
        // The second session's own registry, not the previous session's.
        assert_eq(bar.get("wb-second").unwrap_or(""), "two")
        assert_false(bar.contains("wb-first"))
        // The resident segments ride along: the seeded counters and the
        // manager's model segment are part of the same projection.
        assert_eq(bar.get("turns").unwrap_or(""), "0")
        assert_true(bar.contains("model"))
        // Bar after snapshot: the snapshot feeds the model fields first.
        let snapshot_at = switch_last_snapshot_index(frames, second, before)
        assert_true(snapshot_at >= 0 && render_at > snapshot_at)
      }
      None => fail("cached switch did not re-emit the statusbar registry")
    }
    let middle = frames.length()
    match runtime.switch_session(first) {
      Ok(_) => ()
      Err(reason) => fail("switch back to first session failed: " + reason)
    }
    match switch_statusbar_render(frames, first, middle) {
      Some((render_at, entries)) => {
        let bar = switch_entries_map(entries)
        assert_eq(bar.get("wb-first").unwrap_or(""), "one")
        assert_false(bar.contains("wb-second"))
        assert_eq(bar.get("turns").unwrap_or(""), "0")
        assert_true(bar.contains("model"))
        let snapshot_at = switch_last_snapshot_index(frames, first, middle)
        assert_true(snapshot_at >= 0 && render_at > snapshot_at)
      }
      None => fail("switch back did not re-emit the first registry")
    }
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// The resync path re-projects the active bar directly, so a freshly
/// attached connection gets the full current strip even when the counter
/// reseed is the only other traffic.
async test "republish_status re-emits the active bar registry" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-resync-bar-")
    let (runtime, frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
    )
    let first = runtime.active_session_id()
    runtime.active().active().statusbar.set_segment(
      source="cetas-wb-k2",
      segment="wb-first",
      value="one",
    )
    let before = frames.length()
    runtime.republish_status()
    match switch_statusbar_render(frames, first, before) {
      Some((_, entries)) => {
        let bar = switch_entries_map(entries)
        assert_eq(bar.get("wb-first").unwrap_or(""), "one")
        assert_eq(bar.get("turns").unwrap_or(""), "0")
      }
      None => fail("republish_status did not re-emit the statusbar registry")
    }
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
