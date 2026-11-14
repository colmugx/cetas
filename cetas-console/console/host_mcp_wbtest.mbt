///|
/// `/mcp login` interception: the host, not the bridge's read-only `mcp`
/// command, owns the interactive OAuth action. The network half needs a live
/// authorization server, so these cover the routing contract: only `mcp` +
/// `action: login` is intercepted, a missing server is refused before any
/// connection work, and every other shape falls through to the ports loop.

///|
async test "mcp login interception routes only the interactive login action" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-mcp-login-")
    let home = permission_fixture("mcp-login")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-go", "cetas-go/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let session_id = runtime.active_session_id()
    // A login without a server name is refused before the bridge is touched.
    let missing = runtime.mcp_login_outcome(
      session_id,
      "mcp",
      Json::object({ "action": Json::string("login") }),
    )
    match missing {
      Some(@posoco.CommandOutcome::Failure(reason~)) =>
        assert_true(reason.contains("requires a server name"))
      _ => fail("a nameless login must fail loudly")
    }
    // Any other action keeps flowing to the bridge's own `mcp` command.
    assert_true(
      runtime.mcp_login_outcome(
        session_id,
        "mcp",
        Json::object({ "action": Json::string("status") }),
      )
      is None,
    )
    // A different command id is never intercepted, even with a login action.
    assert_true(
      runtime.mcp_login_outcome(
        session_id,
        "model",
        Json::object({ "action": Json::string("login") }),
      )
      is None,
    )
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
