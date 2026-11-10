///|
/// Whitebox tests for the additive host-side session prefetch: composing a
/// handle without activating it, and the out-of-band host event channel the
/// async switch completion rides. The fixture is the permission tests'
/// offline provider home (static catalog, no credentials, no network).

///|
async test "prefetch_session cache hit keeps the active session and emits nothing" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-prefetch-hit-")
    let home = permission_fixture("prefetch-hit")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-native", "cetas-native/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let frames : Array[String] = []
    runtime.attach_sink(fn(frame) { frames.push(frame) })
    let active_before = runtime.active_session_id()
    // The active session is by definition already composed: prefetch must be
    // a pure cache hit that neither moves the active session nor emits.
    let outcome = runtime.prefetch_session(active_before)
    assert_true(outcome is Ok(_))
    assert_eq(runtime.active_session_id(), active_before)
    assert_eq(frames.length(), 0)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
async test "prefetch_session warms an inactive handle and rejects malformed ids" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-prefetch-miss-")
    let home = permission_fixture("prefetch-miss")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-native", "cetas-native/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let frames : Array[String] = []
    runtime.attach_sink(fn(frame) { frames.push(frame) })
    // A journal id the process has not composed yet: prefetch composes the
    // handle while the active session stays untouched and nothing is emitted.
    let first = runtime.active_session_id()
    let second = permission_ok(runtime.new_session())
    assert_eq(runtime.active_session_id(), second)
    // new_session broadcast its own snapshot; the assertions below count
    // only frames produced by the prefetch calls themselves.
    let frames_before = frames.length()
    let outcome = runtime.prefetch_session(first)
    assert_true(outcome is Ok(_))
    assert_eq(runtime.active_session_id(), second)
    assert_eq(frames.length(), frames_before)
    // A malformed id is refused by the catalog's stem validation; it must
    // not compose anything, move the session, or emit.
    let malformed = runtime.prefetch_session("no/such/id")
    assert_true(malformed is Err(_))
    assert_eq(runtime.active_session_id(), second)
    assert_eq(frames.length(), frames_before)
    // The warmed id now switches without recomposing: the handle cache
    // answers and the active session moves exactly once.
    let switched = permission_ok(runtime.switch_session(first))
    assert_eq(switched, first)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
async test "composition after the shutdown sweep is refused without installing" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-prefetch-stop-")
    let other = @fs.tmpdir(prefix="cetas-prefetch-stop-other-")
    let home = permission_fixture("prefetch-stop")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-native", "cetas-native/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let frames : Array[String] = []
    runtime.attach_sink(fn(frame) { frames.push(frame) })
    let second = permission_ok(runtime.new_session())
    let handles_before = runtime.active().handles.length()
    // The sweep fences every composer: no handle or workspace may appear
    // after it, because their scopes would park on close signals nobody
    // will send again.
    runtime.shutdown_all()
    let never_composed = @cetas_core.mint_session_id()
    assert_true(runtime.prefetch_session(never_composed) is Err(_))
    assert_true(runtime.switch_workspace(other) is Err(_))
    assert_true(runtime.new_session() is Err(_))
    assert_eq(runtime.active().handles.length(), handles_before)
    ignore(second)
    @fs.remove(other) catch {
      _ => ()
    }
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
async test "emit_host_event reaches the sink but not the wire log" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-prefetch-oob-")
    let home = permission_fixture("prefetch-oob")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-native", "cetas-native/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let frames : Array[String] = []
    runtime.attach_sink(fn(frame) { frames.push(frame) })
    let trace_before = runtime.hub.trace.length()
    runtime.emit_host_event("s-x", "session.switched", extra=[
      ("snapshot", Json::object(Map::from_array([]))),
    ])
    assert_eq(frames.length(), 1)
    assert_true(frames[0].contains("\"session.switched\""))
    assert_true(frames[0].contains("\"s-x\""))
    // Out-of-band is realtime-only: the rolling wire log must not grow.
    assert_eq(runtime.hub.trace.length(), trace_before)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
