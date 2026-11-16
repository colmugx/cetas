///|
/// Two WebSocket-equivalent subscribers must keep independent Session
/// selections even when the process-global active Session changes.
async test "two surfaces attach independently and scope UI responses" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-surface-bind-")
    let (runtime, _native_frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
    )
    let first_session = runtime.active_session_id()
    let second_session = "cetas-17943000999"
    match runtime.switch_session(second_session) {
      Ok(_) => ()
      Err(reason) => fail("fixture session switch: " + reason)
    }
    let frames_a : Array[String] = []
    let frames_b : Array[String] = []
    let a = runtime.subscribe_events(fn(frame) { frames_a.push(frame) })
    let b = runtime.subscribe_events(fn(frame) { frames_b.push(frame) })
    match runtime.attach_surface(a, None, Some(first_session)) {
      Ok(id) => assert_eq(id, first_session)
      Err(reason) => fail("attach surface A: " + reason)
    }
    match runtime.attach_surface(b, None, Some(second_session)) {
      Ok(id) => assert_eq(id, second_session)
      Err(reason) => fail("attach surface B: " + reason)
    }
    // Attaches must neither mutate the global picker nor reset the other tab.
    assert_eq(runtime.active_session_id(), second_session)
    assert_eq(runtime.surface_session_id(a), Some(first_session))
    assert_eq(runtime.surface_session_id(b), Some(second_session))
    let count_a = frames_a.length()
    let count_b = frames_b.length()
    runtime.emit_event(first_session, "t-1", "turn.accepted")
    assert_eq(frames_a.length(), count_a + 1)
    assert_eq(frames_b.length(), count_b)
    runtime.emit_event(second_session, "t-2", "turn.accepted")
    assert_eq(frames_a.length(), count_a + 1)
    assert_eq(frames_b.length(), count_b + 1)
    let (request_id, _) = runtime.ui_registry.register(session_id=first_session)
    match runtime.resolve_ui_for_surface(b, request_id, "{\"yes\":true}") {
      Ok(_) => fail("other Session was allowed to answer UI request")
      Err(_) => ()
    }
    assert_true(runtime.ui_registry.pending.contains(request_id))
    match runtime.resolve_ui_for_surface(a, request_id, "{\"yes\":true}") {
      Ok(_) => ()
      Err(reason) => fail("owner Session UI reply rejected: " + reason)
    }
    assert_false(runtime.ui_registry.pending.contains(request_id))
    // A detached subscriber must not invalidate B's Session.
    runtime.unsubscribe_events(a)
    assert_eq(runtime.surface_session_id(a), None)
    assert_eq(runtime.surface_session_id(b), Some(second_session))
    runtime.unsubscribe_events(b)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
