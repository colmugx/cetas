///|
/// Contract coverage for Cetas' host-owned subagent composition.

///|
fn subagent_test_slot(
  id : String,
  model : &@posoco.ModelPort,
) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id~,
    label=id,
    provider_id="test",
    model_id=id,
    port=model,
  )
}

///|
fn subagent_test_composer(router : @llm.RouterModelPort) -> CetasChildComposer {
  let fs = @workspace.NativeWorkspaceFs()
  CetasChildComposer(
    parent_router=router,
    context_fs=fs,
    feature_fs=fs,
    cwd=".",
    home=".",
  )
}

///|
fn subagent_test_spec(
  slot : String,
  tools : Array[String],
) -> @subagent.ChildSpec {
  {
    task: "inspect the workspace",
    kind_name: "test",
    session_id: "subagent-test",
    resuming: false,
    tools,
    skills: None,
    mode: @permission.PermissionMode::ReadOnly,
    system_prompt: "You are a test child.",
    slot,
    effort: None,
    context_files: false,
    observers: [],
  }
}

///|
async test "subagent child sees only requested core tools and never agent" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/a", model as &@posoco.ModelPort)],
    default_slot_id="test/a",
  )
  let composer = subagent_test_composer(router)
  let child = @subagent.ChildComposer::compose(
    composer,
    subagent_test_spec("test/a", ["read", "glob", "grep"]),
  )
  ignore(
    child.run_scoped(async fn(agent) {
      agent.run_turn(@posoco.tk_user_msg("go"), "subagent-test")
    }),
  )

  assert_eq(model.received_tools.length(), 1)
  let names = model.received_tools[0].map(fn(def) { def.name.to_string() })
  assert_eq(names, ["read", "glob", "grep"])
  assert_false(names.contains("agent"))
  assert_false(names.contains("activate_skill"))
}

///|
async test "subagent child model selection does not mutate parent router" {
  let a = @posoco.ScriptedModel([])
  let b = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[
      subagent_test_slot("test/a", a as &@posoco.ModelPort),
      subagent_test_slot("test/b", b as &@posoco.ModelPort),
    ],
    default_slot_id="test/a",
  )
  let composer = subagent_test_composer(router)
  ignore(
    @subagent.ChildComposer::compose(composer, subagent_test_spec("test/b", [])),
  )
  assert_eq(router.active_slot_id(), "test/a")
  assert_true(router.active_effort() is None)
}

///|
async test "subagent composer rejects recursive agent tool even in malformed spec" {
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/a", model as &@posoco.ModelPort)],
    default_slot_id="test/a",
  )
  let composer = subagent_test_composer(router)
  let result : Result[@posoco.Agent, @subagent.ComposerError] = Ok(
    @subagent.ChildComposer::compose(
      composer,
      subagent_test_spec("test/a", ["agent"]),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@subagent.ComposerError::Failed(reason)) =>
      assert_true(reason.contains("not a reconstructable Cetas core tool"))
    _ => fail("recursive agent tool must be rejected by the host composer")
  }
}
