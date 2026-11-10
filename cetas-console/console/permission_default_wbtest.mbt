///|
/// One throwaway real-filesystem fixture: a home whose `settings.json` names a
/// provider with a static offline catalog (no credentials, no network) plus an
/// independent workspace directory. Platform assembly reads the native fs, so
/// the fake-fs seam of cetas-core is not reusable here.
async fn permission_fixture(label : String) -> String {
  let root = @fs.tmpdir(prefix="cetas-permission-" + label + "-")
  let fs = @workspace.NativeWorkspaceFs()
  fs.mkdir(root + "/.cetas", recursive=true) catch {
    error => abort("permission fixture home failed: " + error.to_string())
  }
  fs.write_file(
    root + "/.cetas/settings.json",
    "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
  ) catch {
    error => abort("permission fixture settings failed: " + error.to_string())
  }
  root
}

///|
/// Best-effort fixture teardown; a leaked temp dir must not fail an assertion
/// that already ran.
async fn permission_fixture_cleanup(root : String) -> Unit noraise {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
/// Host commands report failure as `Result`; a fixture step that cannot run is a
/// broken test precondition, not an assertion about permission policy.
fn[T] permission_ok(result : Result[T, String]) -> T {
  match result {
    Ok(value) => value
    Err(message) => abort("console permission fixture: " + message)
  }
}

///|
/// The `permission` field of the most recent `session.snapshot` frame — the
/// same frame a host's sink receives, so an assertion here cannot be satisfied
/// by a statusbar label that diverges from the runtime policy.
fn permission_last_snapshot(frames : Array[String]) -> String {
  for index in 0..<frames.length() {
    let frame = frames[frames.length() - 1 - index]
    let parsed = @json.parse(frame) catch { _ => continue }
    let fields = match parsed {
      Json::Object(fields) => fields
      _ => continue
    }
    let is_snapshot = match fields.get("type") {
      Some(Json::String("session.snapshot")) => true
      _ => false
    }
    if !is_snapshot {
      continue
    }
    match fields.get("permission") {
      Some(Json::String(mode)) => return mode
      _ => ()
    }
  }
  abort("no session.snapshot frame reached the sink")
}

///|
/// The `permission` field of the boot frame (`runtime_json`), i.e. what a host
/// announces before any live event: it must agree with the enforced policy, not
/// report a posture the tools never received.
fn permission_runtime_json(runtime : ConsoleRuntime) -> String {
  let fields = match runtime.runtime_json() {
    Json::Object(fields) => fields
    _ => abort("runtime json must be an object")
  }
  match fields.get("permission") {
    Some(Json::String(mode)) => mode
    _ => abort("runtime json must carry a permission field")
  }
}

///|
/// Snapshot issued after the last host command, so the assertion reads the live
/// runtime posture rather than a frame captured during composition.
fn permission_snapshot_now(
  runtime : ConsoleRuntime,
  frames : Array[String],
) -> String {
  let before = frames.length()
  runtime.emit_active_snapshot()
  let fresh : Array[String] = []
  for index = before; index < frames.length(); index = index + 1 {
    fresh.push(frames[index])
  }
  permission_last_snapshot(fresh)
}

///|
/// Compose one real ConsoleRuntime for the host startup policy under test.
async fn permission_mount(
  permission_mode : @permission.PermissionMode,
  cwd : String,
  group : @async.TaskGroup[Unit],
  native_ui~ : Bool = false,
) -> (ConsoleRuntime, Array[String], String) {
  let home = permission_fixture("mount")
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let config = console_config(
    fs,
    home,
    "cetas-native",
    "cetas-native/0.1",
    native_ui~,
    permission_mode~,
  )
  let runtime = compose_console_runtime(config, cwd, group)
  let frames : Array[String] = []
  runtime.attach_sink(fn(frame) { frames.push(frame) })
  (runtime, frames, home)
}

///|
/// The shared default stays WorkspaceWrite, and an explicit host policy is
/// carried verbatim instead of being flattened onto that default.
test "console config defaults to workspace_write and keeps an explicit host policy" {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let shared = console_config(
    fs, "/tmp/cetas-permission", "cetas-web", "cetas-web/0.1",
  )
  assert_true(shared.permission_mode is @permission.WorkspaceWrite)
  let native = console_config(
    fs,
    "/tmp/cetas-permission",
    "cetas-native",
    "cetas-native/0.1",
    permission_mode=@permission.Yolo,
  )
  assert_true(native.permission_mode is @permission.Yolo)
}

///|
/// Default host policy: the first workspace, a newly minted session, and a
/// workspace composed on first switch all stay WorkspaceWrite.
async test "default host policy holds for first, new session, and new workspace" {
  @async.with_task_group(group => {
    let first_cwd = @fs.tmpdir(prefix="cetas-permission-ws-a-")
    let second_cwd = @fs.tmpdir(prefix="cetas-permission-ws-b-")
    let (runtime, frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      first_cwd,
      group,
    )
    assert_eq(permission_snapshot_now(runtime, frames), "workspace_write")
    assert_eq(permission_runtime_json(runtime), "workspace_write")
    let session = permission_ok(runtime.new_session())
    assert_eq(session, runtime.active_session_id())
    assert_eq(permission_snapshot_now(runtime, frames), "workspace_write")
    let switched = permission_ok(runtime.switch_workspace(second_cwd))
    assert_eq(switched, runtime.active_workspace())
    assert_eq(permission_snapshot_now(runtime, frames), "workspace_write")
    runtime.shutdown_all()
    permission_fixture_cleanup(first_cwd)
    permission_fixture_cleanup(second_cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// A host that resolved Yolo at startup (the native terminal host) gets Yolo on
/// the first session, on new sessions, and on workspaces composed later — one
/// policy owned by the config, not a second hardcoded seed per workspace.
async test "explicit yolo host policy seeds first, new session, and new workspace" {
  @async.with_task_group(group => {
    let first_cwd = @fs.tmpdir(prefix="cetas-permission-yolo-a-")
    let second_cwd = @fs.tmpdir(prefix="cetas-permission-yolo-b-")
    let (runtime, frames, home) = permission_mount(
      @permission.Yolo,
      first_cwd,
      group,
    )
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    assert_eq(permission_runtime_json(runtime), "yolo")
    ignore(permission_ok(runtime.new_session()))
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    ignore(permission_ok(runtime.switch_workspace(second_cwd)))
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    runtime.shutdown_all()
    permission_fixture_cleanup(first_cwd)
    permission_fixture_cleanup(second_cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// Explicit narrowing survives the same three seams: a ReadOnly host policy is
/// never widened by composing a session or a second workspace.
async test "explicit readonly host policy never widens" {
  @async.with_task_group(group => {
    let first_cwd = @fs.tmpdir(prefix="cetas-permission-ro-a-")
    let second_cwd = @fs.tmpdir(prefix="cetas-permission-ro-b-")
    let (runtime, frames, home) = permission_mount(
      @permission.ReadOnly,
      first_cwd,
      group,
    )
    assert_eq(permission_snapshot_now(runtime, frames), "readonly")
    ignore(permission_ok(runtime.new_session()))
    assert_eq(permission_snapshot_now(runtime, frames), "readonly")
    ignore(permission_ok(runtime.switch_workspace(second_cwd)))
    assert_eq(permission_snapshot_now(runtime, frames), "readonly")
    runtime.shutdown_all()
    permission_fixture_cleanup(first_cwd)
    permission_fixture_cleanup(second_cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// Runtime `/permission` switching stays an explicit host command: accepted
/// values move the live session, unknown values fail closed without touching the
/// current posture, and a workspace composed afterwards takes the host startup
/// policy rather than the last interactive switch.
async test "runtime permission switches are explicit and unknown modes fail closed" {
  @async.with_task_group(group => {
    let first_cwd = @fs.tmpdir(prefix="cetas-permission-switch-a-")
    let second_cwd = @fs.tmpdir(prefix="cetas-permission-switch-b-")
    let (runtime, frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      first_cwd,
      group,
    )
    assert_eq(permission_snapshot_now(runtime, frames), "workspace_write")
    ignore(permission_ok(runtime.set_permission("yolo")))
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    assert_eq(permission_runtime_json(runtime), "yolo")
    ignore(permission_ok(runtime.new_session()))
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    // Unknown spellings, including `auto` (no DecisionPort composed) must not
    // change — let alone raise — the effective posture.
    for unknown in ["Yolo", "always", "yolo ", "", "unknown", "auto"] {
      match runtime.set_permission(unknown) {
        Ok(_) => fail("permission mode '" + unknown + "' must be rejected")
        Err(_) => ()
      }
      assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    }
    // A later workspace is composed from the host startup policy, not from the
    // interactive switch that only applied to the current workspace.
    ignore(permission_ok(runtime.switch_workspace(second_cwd)))
    assert_eq(permission_snapshot_now(runtime, frames), "workspace_write")
    runtime.shutdown_all()
    permission_fixture_cleanup(first_cwd)
    permission_fixture_cleanup(second_cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// Cross-workspace resume is atomic and carries the live permission: an
/// invalid seed refuses before anything is composed, a never-opened workspace
/// is seeded from the inherited mode instead of the startup policy, and an
/// already-open workspace keeps the permission it has.
async test "resume_workspace_session is atomic and inherits the live permission" {
  @async.with_task_group(group => {
    let first_cwd = @fs.tmpdir(prefix="cetas-permission-xw-a-")
    let second_cwd = @fs.tmpdir(prefix="cetas-permission-xw-b-")
    let (runtime, frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      first_cwd,
      group,
    )
    // Narrow the live workspace; the resume below must not widen it back.
    ignore(permission_ok(runtime.set_permission("readonly")))
    assert_eq(permission_snapshot_now(runtime, frames), "readonly")
    let session_id = "cetas-1794231235077"
    // An invalid permission name refuses before anything is composed.
    match
      runtime.resume_workspace_session(second_cwd, session_id, Some("yolo!!")) {
      Ok(_) => fail("an invalid permission name must be refused")
      Err(reason) => assert_true(reason.contains("permission mode"))
    }
    assert_eq(runtime.active_cwd, first_cwd)
    // Success: the never-opened workspace inherits the live readonly mode.
    let resumed = permission_ok(
      runtime.resume_workspace_session(second_cwd, session_id, Some("readonly")),
    )
    assert_eq(resumed, session_id)
    assert_eq(runtime.active_cwd, second_cwd)
    assert_eq(permission_snapshot_now(runtime, frames), "readonly")
    // An already-open workspace keeps its own mode on a later resume.
    ignore(permission_ok(runtime.set_permission("yolo")))
    ignore(
      permission_ok(
        runtime.resume_workspace_session(
          second_cwd,
          session_id,
          Some("readonly"),
        ),
      ),
    )
    assert_eq(permission_snapshot_now(runtime, frames), "yolo")
    runtime.shutdown_all()
    permission_fixture_cleanup(first_cwd)
    permission_fixture_cleanup(second_cwd)
    permission_fixture_cleanup(home)
  })
}
