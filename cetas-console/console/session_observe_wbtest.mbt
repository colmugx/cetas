///|
/// `observe_session_json` is the owner's only answer for a Session another
/// terminal asked to observe. A Session this runtime never composed has no
/// live writer, so the refusal must stay machine-readable: bridge clients
/// turn the `code` field into a typed reject that permits a local writable
/// fallback instead of failing closed on a protocol ambiguity.
async test "observing an uncomposed session refuses with a typed code" {
  @async.with_task_group(async fn(group) {
    @async.with_task_group(async fn(lifetime_group) {
      let cwd = @fs.tmpdir(prefix="cetas-observe-uncomposed-")
      let home = permission_fixture("observe-uncomposed")
      let fs_impl = @workspace.NativeWorkspaceFs()
      let fs : &@workspace.WorkspaceFs = fs_impl
      let config = console_config(fs, home, "cetas-go", "cetas-go/0.1")
      let runtime = compose_console_runtime(
        config,
        cwd,
        group,
        lifetime_group=Some(lifetime_group),
      )
      let refusal = runtime.observe_session_json("never-composed-id")
      let wire = refusal.stringify()
      assert_true(wire.contains("\"error\""))
      assert_true(wire.contains("\"session_not_composed\""))
      runtime.shutdown_all()
      permission_fixture_cleanup(cwd)
      permission_fixture_cleanup(home)
    })
  })
}
