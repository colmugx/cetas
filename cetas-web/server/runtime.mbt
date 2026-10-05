///|
struct WebRuntime {
  agent : @posoco.Agent
  session_id : String
  model : String
  effort : String
  cwd : String
}

///|
async fn compose_web_runtime(
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> WebRuntime raise @posoco.CompositionError {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let warn = fn(text : String) noraise {
    println("cetas-web: " + text)
  }
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=@permission.PermissionMode::ReadOnly,
    mcp_group=Some(group),
    label="cetas-web",
    warn~,
  )
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    label="cetas-web",
    warn~,
  )
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    runtime_group=Some(group),
  )
  {
    agent,
    session_id: @cetas_core.mint_session_id(),
    model: session.router.active_slot_id(),
    effort: session.router.active_effort().unwrap_or("default"),
    cwd,
  }
}
