///|
/// Whitebox tests for idle-handle retirement. The integration fixtures mount
/// real runtimes (offline catalog, throwaway home) exactly like the permission
/// tests, because retirement's safety depends on the real composition path:
/// the scope-release hand-off, the active-session guard and the handle map.

///|
test "retirement predicate requires no live work" {
  assert_true(handle_retirable(false, 0, false, 0))
  assert_false(handle_retirable(true, 0, false, 0))
  assert_false(handle_retirable(false, 1, false, 0))
  assert_false(handle_retirable(false, 0, true, 0))
  assert_false(handle_retirable(false, 0, false, 1))
  assert_false(handle_retirable(true, 2, true, 3))
}

///|
test "child meter tracks live detached children" {
  let meter : NativeChildMeter = { live: Map::from_array([]), }
  assert_eq(meter.live_count(), 0)
  let started : @subagent_kit.SubagentEvent = {
    child_session: "c-1",
    kind: "coder",
    parent_call: "call-1",
    event: @posoco.TurnEvent::TurnStarted,
  }
  meter.observe(started)
  assert_eq(meter.live_count(), 1)
  let chunk : @subagent_kit.SubagentEvent = {
    child_session: "c-1",
    kind: "coder",
    parent_call: "call-1",
    event: @posoco.TurnEvent::TurnCompleted,
  }
  meter.observe(chunk)
  assert_eq(meter.live_count(), 0)
  meter.observe(started)
  let failed : @subagent_kit.SubagentEvent = {
    child_session: "c-1",
    kind: "coder",
    parent_call: "call-1",
    event: @posoco.TurnEvent::TurnFailed("child crashed"),
  }
  meter.observe(failed)
  assert_eq(meter.live_count(), 0)
  // Two children: one finishing must not clear the other.
  let second : @subagent_kit.SubagentEvent = {
    child_session: "c-2",
    kind: "coder",
    parent_call: "call-2",
    event: @posoco.TurnEvent::TurnStarted,
  }
  meter.observe(started)
  meter.observe(second)
  assert_eq(meter.live_count(), 2)
  meter.observe(chunk)
  assert_eq(meter.live_count(), 1)
}

///|
/// Switching through more sessions than the retention ceiling keeps the map
/// bounded, always keeps the active session, and stays resumable: a retired id
/// recomposes on demand.
async test "idle handles retire above the ceiling and stay resumable" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-retire-a-")
    let (runtime, _frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
    )
    let ids : Array[String] = []
    for index = 0; index < MAX_RETAINED_SESSION_HANDLES + 3; index = index + 1 {
      let id = "cetas-17943000000" + index.to_string()
      ids.push(id)
      match runtime.switch_session(id) {
        Ok(_) => ()
        Err(reason) => fail("switch to " + id + " failed: " + reason)
      }
      let workspace = runtime.active()
      assert_true(workspace.handles.length() <= MAX_RETAINED_SESSION_HANDLES)
      assert_true(workspace.handles.contains(id))
      assert_eq(workspace.active_id, id)
    }
    // A retired id recomposes from its journal instead of failing.
    let first = ids[0]
    match runtime.switch_session(first) {
      Ok(resumed) => assert_eq(resumed, first)
      Err(reason) => fail("retired session did not recompose: " + reason)
    }
    assert_eq(runtime.active().active_id, first)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
/// Live work is never retired: a running turn or a detached child keeps the
/// handle in the map even above the ceiling.
async test "busy handles and live children survive retirement pressure" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-retire-b-")
    let (runtime, _frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
      native_ui=true,
    )
    let busy_id = "cetas-17943000100"
    let child_id = "cetas-17943000101"
    match runtime.switch_session(busy_id) {
      Ok(_) => ()
      Err(reason) => fail("busy fixture switch failed: " + reason)
    }
    match runtime.switch_session(child_id) {
      Ok(_) => ()
      Err(reason) => fail("child fixture switch failed: " + reason)
    }
    let workspace = runtime.active()
    match workspace.handles.get(busy_id) {
      Some(handle) => handle.busy = true
      None => fail("busy fixture handle missing")
    }
    // Park one live detached child on the second handle through the same
    // event stream the subagent bridge feeds.
    match workspace.handles.get(child_id) {
      Some(handle) =>
        match handle.children {
          Some(meter) =>
            meter.observe({
              child_session: "c-child",
              kind: "coder",
              parent_call: "call-1",
              event: @posoco.TurnEvent::TurnStarted,
            })
          None => fail("native fixture handle has no child meter")
        }
      None => fail("child fixture handle missing")
    }
    // Push the map past the ceiling: the two guarded handles must survive.
    for index = 0; index < MAX_RETAINED_SESSION_HANDLES + 1; index = index + 1 {
      let id = "cetas-1794300020" + index.to_string()
      match runtime.switch_session(id) {
        Ok(_) => ()
        Err(reason) => fail("pressure switch failed: " + reason)
      }
    }
    let after = runtime.active()
    assert_true(after.handles.contains(busy_id))
    assert_true(after.handles.contains(child_id))
    assert_true(after.handles.length() <= MAX_RETAINED_SESSION_HANDLES + 2)
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
