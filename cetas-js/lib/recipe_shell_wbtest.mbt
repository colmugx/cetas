///|
/// Regression: the composed bash tool must accept background sessions once
/// the host passes its task group — posoco-ext-bash refuses detached
/// execution until `ShellTools::attach` has been called.
async test "recipe bash attaches host group for background sessions" {
  if shell_platform_is_windows() {
    // Background sessions are a bash-extension feature; the Windows build
    // canonicalizes "bash" to ps1, which has no session API.
    return
  }
  @async.with_task_group(async fn(group) {
    let exts = build_cetas_tools(
      ctx={ fs: @workspace.JsWorkspaceFs(), cwd: ".", home: ".", },
      ["bash"],
      host_group=Some(group),
    )
    let provider = match exts[0].manifest().tools {
      [provider, ..] => provider
      _ => fail("bash extension exposes no tool provider")
    }
    let outcome = provider.execute(
      @posoco.ToolCallContext(
        effect_id=@kernel.EffectId::{ value: 1, },
        call_id=@posoco.CallId::unchecked("tc_bg"),
        name=@posoco.ToolName::unchecked("bash"),
        arguments=Json::object(
          Map::from_array([
            ("cmd", Json::string("echo recipe-bg")),
            ("background", Json::boolean(true)),
          ]),
        ),
        register_cancel=fn(_self : &@posoco.ToolCancellable) { () },
      ),
    )
    match outcome {
      @posoco.ToolOutcome::Success(content~, ..) =>
        assert_true(content.contains("session_id"))
      other => fail("expected a background session, got \{other}")
    }
  })
}
