///|
/// The shutdown drain: `shutdown_all` is the single point that outlives the
/// core-async lifetime group's residents. A session composition that began
/// before the stopping fence must settle before the sweep returns — its
/// protected tail starts recovery actors on the lifetime group, and
/// core/async aborts the whole process on a spawn aimed at a terminated
/// group. These tests lock the two halves of that contract: composition
/// bookkeeping is at rest around real composes, and the sweep parks at the
/// drain until the bookkeeping clears.

///|
async test "a real session composition settles the in-flight counter" {
  @async.with_task_group(async fn(group) {
    @async.with_task_group(async fn(lifetime_group) {
      let cwd = @fs.tmpdir(prefix="cetas-drain-compose-")
      let home = permission_fixture("drain-compose")
      let fs_impl = @workspace.NativeWorkspaceFs()
      let fs : &@workspace.WorkspaceFs = fs_impl
      let config = console_config(fs, home, "cetas-go", "cetas-go/0.1")
      let runtime = compose_console_runtime(
        config,
        cwd,
        group,
        lifetime_group=Some(lifetime_group),
      )
      // Boot composes the first session before the runtime value exists, so
      // the counter is at rest the moment composition hands over control.
      assert_eq(runtime.composing_handles, 0)
      let composed = runtime.new_session()
      assert_true(composed is Ok(_))
      // The switch composed under the begin/end_composing accounting pair.
      assert_eq(runtime.composing_handles, 0)
      runtime.shutdown_all()
      permission_fixture_cleanup(cwd)
      permission_fixture_cleanup(home)
    })
  })
}

///|
async test "shutdown_all drains an in-flight composition before returning" {
  @async.with_task_group(async fn(group) {
    @async.with_task_group(async fn(lifetime_group) {
      let cwd = @fs.tmpdir(prefix="cetas-drain-sweep-")
      let home = permission_fixture("drain-sweep")
      let fs_impl = @workspace.NativeWorkspaceFs()
      let fs : &@workspace.WorkspaceFs = fs_impl
      let config = console_config(fs, home, "cetas-go", "cetas-go/0.1")
      let runtime = compose_console_runtime(
        config,
        cwd,
        group,
        lifetime_group=Some(lifetime_group),
      )
      assert_eq(runtime.composing_handles, 0)
      // Simulate a compose parked mid-disk-I/O: the counter is the sweep's
      // only view of it. The sweep must park at the drain until the compose
      // settles, or the host can terminate the lifetime group underneath a
      // protected composition that is about to spawn recovery actors on it.
      runtime.composing_handles = 1
      let settled = Ref(false)
      ignore(
        group.spawn(async fn() {
          runtime.shutdown_all()
          settled.val = true
        }),
      )
      @async.sleep(50)
      assert_false(settled.val)
      runtime.composing_handles = 0
      @async.sleep(50)
      assert_true(settled.val)
      permission_fixture_cleanup(cwd)
      permission_fixture_cleanup(home)
    })
  })
}
